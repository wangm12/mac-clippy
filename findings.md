# Findings

## 2026-08-06 Deep review implementation baseline

- The continuation begins from an already dirty worktree; existing user
  changes are preserved and the implementation stays within the current
  SwiftUI/AppKit architecture.
- `MacClippyRuntime.start()` currently schedules `enforceRetention()` for every
  `UserDefaults.didChangeNotification`, including excluded-app and excluded-
  text edits. The notification has no key in its payload, so the safe fix is a
  retention-key snapshot comparison plus a coalesced delayed maintenance job;
  capture exclusion/pause updates remain immediate.
- `scheduleOCR` currently creates one `Task.detached` per captured image and
  `MacClippyOCRService` decodes the source image at full size before Vision.
  This is a boundedness and peak-memory risk during image-heavy capture.
- Card thumbnails already downsample before SwiftUI, but the model uses an
  unbounded concurrent queue and calls the general `preview(id:)` path. A
  dedicated image-data path, a small decode queue, and same-record in-flight
  completion coalescing are low-risk improvements.
- `ClipboardStore.bodies(for:)` already provides a batch envelope read for
  pinboard projections; history/search projection paths still call the
  single-record `body(for:)` helper repeatedly. This is a later low-risk pass,
  with care needed to preserve the existing skip-on-corrupt-record behavior.
- `.impeccable.md` is absent. Animation changes are therefore held to the
  existing restrained native macOS motion language until the creator confirms
  audience, tone, and performance constraints; no speculative visual redesign
  is being introduced.

## Initial Scope
- The parent worktree contains unrelated dirty changes; target work is confined to `mac-clippy`.
- No planning files existed in the target subtree before this task.

## 2026-08-04 Final cleanup review — initial evidence

- The target directory is presented as untracked by the parent Git worktree (`git status --short -- .` reports `?? ./`), so Git history cannot be used as a safe deletion oracle. Deletions must rely on source/project references and artifact provenance.
- `.gitignore` already excludes `.build/`, `MacClippyKit/.build/`, `.swiftpm/`, `DerivedData/`, `*.xcresult`, and Xcode user state. Build artifacts still need explicit inspection before any removal because the parent worktree is untracked.
- Current source inventory is about 20,079 lines. The largest files remain `MacClippyDock.swift` (3,752), `MacClippyRuntime.swift` (2,485), `MacClippyDockController.swift` (1,416), and `ClipboardStore.swift` (1,039); this is structural debt, not evidence that their code is unused.
- Static marker scan found only two intentional `fatalError("init(coder:)")` guards in the AppKit panel and one comment mentioning deprecated event metadata. No TODO/FIXME/HACK/XXX or `try!` was found in target source/tests.
- `Info.plist` and `project.yml` both define `LSUIElement`, Accessibility, and Input Monitoring usage descriptions. The entitlements plist is intentionally empty; no entitlement should be added without a capability requirement.
- Private-symbol reference scan found two safe removals: `MacClippyMotion.actionBarEnterTransition` has no call site after the selection action bar changed, and `MacClippyDockView.selectionIndex(for:)` has no call site after selection routing moved to the model/policy.
- No unused standalone source file was proven. The public compatibility typealiases and recovery/backup APIs are referenced by tests or runtime and were retained.
- `build/`, `MacClippyKit/build/`, `.build/`, and `MacClippyKit/.build/` contain compiler/test outputs only. They are safe to remove after verification and are now explicitly ignored; historical plan/report documents are retained because they are user-authored review context, not generated code.

## 2026-08-04 Final technical audit

### Feature coverage

- Capture: multi-UTI reads, lazy-provider retry, type-only unavailable/oversized markers, change-count fast path, pause/exclusion rules, and internal-write sentinel are implemented.
- Storage: AES-GCM payload encryption, Keychain device key, separate GRDB databases, encrypted external blobs, WAL/recovery health checks, deletion journal replay, FTS repair, backup validation, and orphan cleanup are implemented.
- Search: FTS plus structured clauses for type/app/label/OCR/date, pagination, stale-result protection, and reload failure snapshot retention are covered by tests.
- Copy/paste: single, plain-text, transformed, batch, ordered and queue paste paths distinguish injected versus manual fallback and update frequency only after successful injection.
- Media/files: background OCR, bounded card thumbnails, downsampled Preview images, background file icons, video/file routing, Quick Look-style preview, and source-app presentation are present.
- Organization: pinboards, drag/drop pinning, categories, multi-selection, labels, snippets, manual snippet editor, trigger modes, and memory-backed snippet lookup are present.
- Lifecycle/settings: menu-bar-only launch, frontmost Settings routing, permission status/actions, Privacy notice, launch-at-login wiring, retention maintenance, diagnostics/export, and degraded storage UX are present.

### Audit health score

| Dimension | Score | Evidence |
|---|---:|---|
| Accessibility | 3/4 | Native controls, keyboard routing, labels/help, permission fallbacks, and reduced-motion support exist; real TCC/CGEvent verification is still external. |
| Performance | 3/4 | Polling fast path, background queues, cache cost limit, bounded preview rendering, narrowed paste lock, and cancellable search checks are present; Instruments data is still missing. |
| Theming | 3/4 | Dock tokens and system colors are mostly centralized; a few Preview/settings colors remain direct values. |
| Responsive/layout | 3/4 | Multi-display/full-screen frame policies and clamped Preview layout exist; fixed utility-window dimensions and native macOS-only assumptions remain. |
| Anti-patterns | 4/4 | No gradients, web wrapper, private API, decorative data visualizations, or generic web dashboard pattern found. |
| **Total** | **16/20** | **Good; address release gates and remaining structural debt.** |

### Release findings by severity

- **[P1] Public privacy-policy URL is not supplied.** `MacClippyPrivacyNoticePolicy` explicitly says a formal public URL is still required. Apple review requires an in-app and App Store Connect privacy policy link; this is a release blocker until the product owner provides the URL and final text.
- **[P1] Distribution evidence is incomplete.** Current evidence is an unsigned/ad-hoc Debug build plus passing local tests. Developer ID signing, hardened-runtime signature verification, notarization/stapling, Gatekeeper, clean-user install/update, and clean TCC/Keychain/Accessibility/Input Monitoring behavior still require a release environment and credentials.
- **[P1 conditional] App Sandbox is not enabled.** `MacClippy/MacClippy.entitlements` is empty. This is acceptable for direct distribution only if the chosen distribution channel permits it; a Mac App Store submission needs an explicit sandbox/capability review because the app uses pasteboard, Accessibility, Input Monitoring, Keychain, and event injection.
- **[P2] Metadata/FTS privacy boundary remains plaintext.** Payload/blob encryption is strong, but previews, OCR text, labels, source metadata, and FTS are intentionally local plaintext for fast search. This is disclosed in the notice but should be a deliberate product/privacy-policy decision.
- **[P2] Real-system integration coverage is incomplete.** Automated tests use injected pasteboards/injectors and policy fixtures; real lazy NSPasteboard providers, Vision fixtures, CGEvent expansion, permission revocation, and non-QWERTY/target-app matrices remain unverified.
- **[P2] Structural maintenance debt remains.** `MacClippyDock.swift`, `MacClippyRuntime.swift`, `MacClippyDockController.swift`, and `ClipboardStore.swift` exceed SwiftLint size/complexity limits. This is not a correctness failure, but it increases future change risk and keeps scoped SwiftLint non-zero.
- **[P3] Build-tool noise remains.** Xcode reports the local CoreSimulator framework-version mismatch and skips AppIntents metadata for the non-AppIntents target. Neither blocks the macOS build, but the CI/toolchain should be normalized before shipping.

### Positive findings

- The most concrete historical performance issue—full pasteboard materialization every 250 ms—has been corrected with a cheap generation check before reads.
- Retention is now invoked at startup and hourly, with pinboard protection and deletion-journal recovery rather than silent best-effort deletion.
- Failure paths preserve usable UI snapshots, expose redacted diagnostics, and distinguish manual fallback from successful injection.
- The source tree contains no TODO/FIXME/HACK/XXX markers, no hard-coded secrets, no private API selectors, and no proven unused source file after the reference scan.

## Dock Structure
- `MacClippyDockController` owns the `NSPanel` lifecycle and currently offsets the fixed 360pt panel by 16pt for both entrance and exit; it already avoids resizing width/height.
- `MacClippyDockView` owns tabs, action strip, horizontal card carousels, and source-colored card rendering.
- Keyboard focus is model-based through `focusedIndex`; left/right changes only one focused card, so focus feedback can be driven by `index == model.focusedIndex` without continuous card animation.
- `MacClippyDockModel.perform` currently reports only errors and optional reload completion, so action feedback needs a non-blocking published state and success callbacks that preserve existing async behavior.
- `project.yml` explicitly lists app source files, so a new motion helper must be added there before `xcodegen generate`.
- Motion token values keep the existing 16pt panel travel but shorten the entrance/exit to 160/110ms; SwiftUI transitions use an 8pt horizontal offset and opacity, while Reduce Motion keeps only instantaneous opacity/state changes.
- Paste results expose `injected` versus `manualPasteRequired`; feedback can be published before the existing close completion without changing the paste flow.

## Display Layout Pass
- `MacClippyDisplayLayout` sorts display rects by origin and size before selecting, making fallback deterministic while retaining CGRect half-open boundary behavior for adjacent displays.
- Preview frames are clamped to the selected display's `visibleFrame`, constrained to start above the full-width dock, and shrink when the available visible height is smaller than the preferred preview.
- The controller observes `NSApplication.didChangeScreenParametersNotification` only while monitors are active, invalidates dock and preview animation generations, and applies both final frames without animation.
- Screen-change fallback order is cursor screen, still-valid `dockPanel.screen`, then `NSScreen.main`; the old panel midpoint is not used for that fallback path.

## Category Rail Pass
- The action strip is no longer part of the normal panel layout; action feedback is a small non-interactive overlay.
- `MacClippyCategoryColorPolicy` preserves explicit pinboard colors and uses a stable FNV-1a selection from an accessible palette otherwise.
- Clipboard cards register `public.text` data containing only their valid RecordID; snippets intentionally have no drag provider.
- Runtime pinning validates both board and clipboard record under the existing store lock and no-ops duplicate membership.

## Preview Arrow Beep Review
- The latest Debug app was launched from `.build/DerivedData/Build/Products/Debug/MacClippy.app` after stopping stale MacClippy processes.
- A real `Command-Shift-V` then Space sequence opened the dock and preview. Screenshots show right-arrow moving focus from `second first` to `alpha`, and left-arrow returning, so the controller action is firing.
- The preview is a separate `.nonactivatingPanel` that cannot become key. The controller local key monitor currently consumes horizontal arrow keyDown/keyUp events, but `MacClippyPanelArrowInterceptionPolicy` is no longer wired to a panel `sendEvent` override. The remaining risk is an unhandled event reaching the preview SwiftUI/AppKit responder chain and calling the macOS prohibited-operation beep.
- The minimal fix wires the policy into both panel `sendEvent` paths. The Dock panel enables interception only while previewing; the Preview panel intercepts only visible, unmodified horizontal arrows. The controller remains the single navigation action, so panel interception is a fallback sink and cannot move focus twice.
- Live verification showed a second arrow could be consumed without moving when the event bypassed the local monitor. The panel interception now calls the controller's shared navigation helper for keyDown as a fallback, while keyUp is only swallowed.

## 2026-07-25 Follow-up: `⌘⇧V` picker behavior
- User clarified that the dock must be opened through `⌘⇧V`; the current work should be verified from that hotkey path, not by launching the app window directly.
- In-app Browser has no controllable tabs because MacClippy is a native AppKit/SwiftUI app, so native UI observation requires the Computer Use surface.
- Current card click action calls `model.focus(item)` for a plain click, but does not put that item into `selection`; the visible non-preview border is driven only by `isSelected`. This can make a clicked card appear unselected even though `focusedIndex` changed.
- Current Space policy returns `.none` when `focusedPreviewTarget` is nil. If the hotkey opens before the model has a valid visible card, returning the original event allows AppKit to beep; the dock session should consume the picker keys whenever it owns the active `⌘⇧V` interaction, while only opening Preview when a target exists.
- Paste's public product flow describes a single keyboard shortcut to open the picker, then preview/edit and quickly choose a clipboard item; its web copy explicitly calls out previewing links, images, and files.
- Maccy's open-source README documents a keyboard-first native picker: popup via a global shortcut, then choose an item by Enter or click. It treats opening and item choice as separate steps, which matches making card focus/selection explicit after `⌘⇧V` opens.
- Maccy reference URL: https://github.com/p0deje/Maccy. Paste reference URL: https://pasteapp.io/.
- The model already has focusSelection(at:) and the pure focusing policy; the fix only needs to seed that state after a successful reload when the visible list has no selection.
- The controller's preview Space branch previously allowed .none to continue through later responder handling; the follow-up consumes that key while Preview is visible, including transient no-target states.
- Live command-shift-V verification on the rebuilt Debug app: dock appeared with the first card highlighted; Space opened the Preview; Right moved focus to the second card and then to alpha; Space closed Preview while leaving the dock open. The screenshots showed the Preview content and card highlight moving together.
- Added an AppKit panel fallback sink for picker keyDown/keyUp events. The Dock panel now forwards Space and plain arrows to the controller when local monitoring is bypassed; the Preview panel forwards Space and already intercepts arrows. Key-up events are consumed by the same path, preventing responder-chain beep after navigation.

## 2026-07-27 Review implementation continuation
- The prior implementation already addressed the first-phase clipboard, snippet, retention, blob lifecycle, structured-search, paste-lock, reload, thumbnail, preview, settings, and menu-bar configuration findings.
- Current verification boundary: package tests, Debug arm64 build, and scheme-qualified Debug app tests are available; formal Release signing/notarization and Instruments profiling are not available from the current guarded environment.
- The existing planning file contains earlier UI work; this review is appended as a separate continuation and does not rewrite that history.
- Lazy-provider retry now preserves the initial full `PasteboardChange` and updates only unavailable UTI slots across polls; the regression verifies one full read and two targeted rereads.
- The full SwiftLint tree still reports structural violations in the intentionally large runtime/dock/store files and scans generated/third-party package artifacts. The changed retry files have no SwiftLint errors; the retry test file retains one file-length warning after the added assertions.
- Final built plist contains `LSUIElement`, Accessibility, and Input Monitoring usage descriptions. The Debug artifact is adhoc/linker-signed with no TeamIdentifier, so it is not evidence of Developer ID distribution readiness.
- The latest app-test xcresult reports cancellation while waiting for XCTest workers to materialize; no product test assertion ran in that invocation. Package tests remain the reliable automated result in this environment.

## 2026-07-31 Prod-readiness audit correction and research

- A subsequent scheme-qualified Debug app-test run completed successfully on the
  local arm64 MacBook Pro running macOS 26.5.2: 114 tests passed, 0 failed, 0
  skipped. This supersedes the earlier worker-launch limitation recorded above;
  the earlier limitation remains historical only.
- `swift test --package-path mac-clippy/MacClippyKit` also passed 179 tests with
  0 failures. These are strong regression signals for pure core/UI-policy logic,
  not proof of real TCC, lazy-provider, CGEvent, Keychain, signing, or multi-
  display behavior.
- The built Debug artifact is still ad-hoc/linker-signed: `TeamIdentifier = not
  set`, `Signature = adhoc`. `project.yml` disables signing for Debug and the
  Makefile always builds/tests with `CODE_SIGNING_ALLOWED=NO`; no notarized
  Release artifact or CI path is currently evidenced.
- The current source has four concrete release risks requiring engineering work:
  `MacClippyRuntime` is `@unchecked Sendable`; `PasteboardObserver` mutates
  timer/handler/generation state outside one lifecycle executor; lazy-provider
  rereads do not revalidate that the system pasteboard `changeCount` is still
  the original generation; and successful record persistence can be followed by
  a logged-only FTS failure, leaving searchable data missing.
- Capture materializes raw representations before the 32 KiB inline spill
  threshold. There is no hard per-representation or total-event byte budget, so
  a hostile/huge advertised UTI can still create excessive memory pressure even
  though large data is eventually blob-backed.
- Defaults currently allow concealed/transient content and unknown UTIs unless
  the user opts into exclusions, while the runtime intentionally captures every
  external representation. This is a product trust risk for passwords, payment
  data, and one-time secrets; safe defaults and an explicit Capture All mode are
  recommended before public release.
- Retention and startup reconciliation are best-effort and conservative, but
  currently do not provide a deletion journal, database `quick_check`/backup-
  restore flow, or a repair path for missing FTS rows. These should be added so
  a force-quit cannot silently degrade history/search integrity.
- Launch-at-login startup still uses `try?` in `MacClippyApp.swift`; the user-
  visible setting can therefore diverge from `SMAppService.status` after a
  registration error.

## Research sources and transferable lessons

- Deck DeepWiki: https://deepwiki.com/yuzeguitarist/Deck — integrity checks,
  backup/recovery, migration repair, bounded inputs, safe blob paths, hotkey
  teardown, paste failure restore, and explicit sync conflict handling.
- Maccy DeepWiki: https://deepwiki.com/p0deje/Maccy — `changeCount` polling,
  concealed/transient/auto-generated filtering, app/regex exclusions, keyboard-
  first picker, multiple pasteboard items, keyboard-layout handling, and
  Universal Clipboard controls.
- Clipy DeepWiki: https://deepwiki.com/Clipy/Clipy — stable Developer ID signing
  is required for persistent Accessibility permission; it also demonstrates
  migration, CI, Sparkle, hotkey persistence, and SQLite history maintenance.
- PasteBar DeepWiki: https://deepwiki.com/PasteBar/PasteBarApp — Tauri/Rust
  architecture, local SQLite, duplicate hashing, lock/passcode UX, collections,
  boards, templates, and explicit accessibility permission handling.
- Product/architecture references: [Paste](https://pasteapp.io/),
  [Maccy](https://github.com/p0deje/Maccy), [Clipy](https://github.com/Clipy/Clipy),
  [PasteBarApp](https://github.com/PasteBar/PasteBarApp),
  [CopyQ](https://github.com/hluk/CopyQ), and
  [Deck](https://github.com/yuzeguitarist/Deck).
- Tauri's official architecture docs describe a WebView frontend, Rust backend,
  and message-passing bridge; its macOS signing docs still require Apple
  signing/notarization infrastructure. This makes Tauri a cross-platform/UI
  choice, not a shortcut around TCC, signing, or crash-hardening:
  https://v2.tauri.app/concept/architecture/ and
  https://v2.tauri.app/distribute/sign/macos/.

## 2026-08-03 P0-A release configuration audit

- The only local signing identity is `Apple Development: frank19970907@gmail.com (777BPJR98D)`; no Developer ID Application identity is installed. No credentials were read or written.
- Before this pass, `project.yml` had `ENABLE_HARDENED_RUNTIME = NO` in Debug and no explicit Hardened Runtime setting for the shipping configuration. `MacClippy/MacClippy.entitlements` is intentionally empty because the app is not sandboxed and currently does not declare app-specific entitlements.
- Added explicit `ENABLE_HARDENED_RUNTIME: YES` to Debug and Release, and disabled base-entitlement injection for Release. The generated project contains these settings.
- Added credential-free scripts for signed archive, strict signature/Gatekeeper verification, and keychain-profile notarization/stapling. They fail closed when Developer ID identity, team, keychain profile, or artifact inputs are missing.
- Added a macOS CI workflow covering project generation, package tests, unsigned app build, and app tests. It does not attempt signing or notarization.
- Actual archive/sign/notarize/Gatekeeper evidence remains blocked by the environment's deploy Guard and the missing Developer ID identity; this is an external release prerequisite, not a code success.

## 2026-08-03 P0-B recovery implementation

- Added schema/integrity-only `MacClippyDatabaseHealthReport` with `quick_check`, foreign-key checks, required-table checks, and bounded statuses (`healthy`, `repairable`, `unrecoverable`). It never includes row values or clipboard text.
- Added cancellable transactional FTS rebuild. Cancellation throws before commit and leaves the previous index intact; repair can be retried from a fresh document snapshot.
- Added `MacClippyBackup` using GRDB's online backup API for clipboard/search/pinboard/snippet databases, plus encrypted blob copying, manifest metadata, blob SHA-256 checksums, validation, and restore-to-a-new-directory. The runtime now exposes an explicit search-repair method and storage health snapshot for future recovery UI.
- Backup testing exposed that a WAL-mode SQLite main file can change bytes during journal finalization while remaining logically identical. Database validation therefore checks file existence/size plus SQLite health and row counts; immutable blob files retain exact SHA-256 verification. This avoids a false corruption result while still detecting missing/corrupt blobs and damaged database structure.
- Added `MacClippyRecoveryTests`: healthy/missing schema, FTS rebuild + cancellation rollback, and four-database/blob backup validation + restore. Focused recovery test passes; full package count is 182 after adding the new tests, with the first full run failing only on the intentionally discovered WAL checksum assumption before the fix.

## 2026-08-03 P0-D diagnostics and recovery UX

- Diagnostics now has bounded in-memory retention and stable redacted event
  codes. Exported data contains health/counter metadata only; it does not
  include clipboard text, OCR, image bytes, file paths, or regex contents.
- Settings can refresh storage health, repair the FTS index off the main
  thread, and export diagnostics through an `NSSavePanel`. The running app
  supplies the live runtime snapshot so export does not open duplicate live
  database handles.
- Launch-at-login errors no longer disappear through `try?` or expose raw
  system error text in Settings; they produce a structured event and a safe
  retry instruction.
- P0-D implementation compiles and package tests/build pass. Remaining P1
  concerns are the runtime's `@unchecked Sendable`, observer lifecycle
  executor, full migration of legacy `NSLog` sites, real TCC/CGEvent/Keychain
  integration, and soak/Instruments evidence.

## 2026-08-03 P1 verification follow-up

- The latest code compiles after a local missing-`return` fix in
  `MacClippyRuntime.diagnosticsStorageSnapshot()`; package and app test suites
  pass at 188/188 and 114/114 respectively.
- `MacClippyRetentionPreferences.exclusionRules(from:)` previously replaced
  `CaptureExclusionRules`' default password-manager exclusions with only the
  user-provided app string. This contradicted the privacy UI and made the safe
  default weaker than intended. The user list now unions with the built-in
  password-manager set; Capture All still bypasses marker-type exclusions but
  not app exclusions.
- Dock and details error surfaces no longer display raw system
  `localizedDescription` values, which could contain paths or database
  context. Reconciliation success now uses the redacted diagnostics channel.
- Earlier app XCTest logs showed libsqlite3 warnings about temporary WAL/SHM
  files being unlinked while open. This was a fixture lifecycle issue and is
  superseded by the explicit close fix recorded below; the latest full run is
  warning-free for SQLite teardown.

## 2026-08-03 Final verification and teardown finding

- Scoped SwiftLint is now reproducible with `swiftlint lint --quiet MacClippy
  MacClippyKit/Sources`. It reports existing large-type/file and line-length
  violations, plus a few older identifier/complexity errors. The review does
  not perform a wholesale lint refactor because that would obscure behavior
  changes and expand the requested scope.
- GRDB `DatabaseQueue` requires explicit close for deterministic file
  lifecycle. `MacClippyDatabase` now closes its queue on deinit; Runtime closes
  all four queues on teardown; DEBUG app tests close them before deleting their
  temporary roots. Full app XCTest no longer emits the prior SQLite
  vnode-unlink warnings.
- Verification evidence after this cleanup: MacClippyKit 188/188, app XCTest
  116/116, `xcodegen generate`, and Debug arm64 build all pass.
- Release compilation/signing remains unverified because the local
  deploy/release Guard blocks the Release build and no Developer ID identity
  or notarization credentials are available. The Debug artifact remains
  ad-hoc and is not distribution evidence.
- Residual release gates remain: `MacClippyRuntime` is still `@unchecked
  Sendable`; real TCC/Accessibility/Input Monitoring/CGEvent/Keychain and
  NSPasteboard integration coverage is absent; 100k-history/20–100MB-image
  soak and Instruments profiling are absent; and an in-app privacy-policy
  destination still needs a product-owned URL/content decision.

## 2026-08-03 Deletion journal replay hardening

- The initial deletion journal stored record IDs only alongside Blob IDs. A
  text-only record therefore created an operation row with no journal rows;
  after a force quit, replay could not know which FTS or pinboard entries to
  remove. Added migration `005-deletion-records` with a dedicated
  `clipboard_deletion_records` table and backfill for existing Blob-bearing
  journal rows.
- `beginDeletion` now persists every present record ID independently and no
  longer converts Blob-reference lookup errors into an empty Blob set. Image
  legacy envelopes are decoded only when the persisted `content_kind` is
  `image`; non-image deletion avoids unnecessary decryption.
- Database health and diagnostics now require the three deletion tables, so a
  missing recovery schema is visible as a repairable/unrecoverable health
  issue rather than silently disabling replay.
- Regression coverage now includes text-only journal retention, Runtime
  replay with the parent row already deleted and FTS still indexed, successful
  Retention journal completion, and Blob deletion failure retaining the
  journal. Targeted package tests: 5/5; Runtime batch tests: 19/19.
- Final verification after project regeneration: MacClippyKit 195/195,
  scheme-qualified App XCTest 117/117 on arm64 macOS 26.5.2, `xcodegen
  generate` passed, and Debug arm64 unsigned build passed. The built plist
  contains `LSUIElement`, Accessibility, and Input Monitoring usage strings;
  the artifact remains ad-hoc signed with no TeamIdentifier.
- The final scoped SwiftLint run still exits 2 on pre-existing structural
  debt: large `MacClippyRuntime`/`MacClippyDock`/`ClipboardStore`, complexity,
  line length, and a few identifier violations. This review deliberately does
  not mix a broad decomposition refactor into recovery behavior changes.

## 2026-08-03 Observer lifecycle and test teardown findings

- The observer's lifecycle state is now serialized on its polling queue. This
  removes the previous cross-thread mutation of timer/handler/generation,
  retry, pause, and exclusion state while keeping configuration calls
  non-blocking for the caller. Focused tests cover ordered concurrent updates;
  package Thread Sanitizer completed 196/196 without a race report.
- A full App XCTest run initially showed SQLite's `vnode unlinked while in
  use` warning despite passing assertions. The warning was deterministic for
  the manual-stop QueuePaste model test: its model retained a secondary
  Runtime sharing the fixture directory, while teardown closed only the main
  Runtime and removed the directory. Explicitly closing the secondary Runtime
  before cleanup removes the warning without changing production behavior.
- Final App XCTest result: 117/117 passed, 0 failed, 0 skipped; no SQLite
  unlink warning in the final run. The only recurring build warning is the
  local CoreSimulator framework version mismatch, which does not affect the
  macOS target.
- Scoped SwiftLint remains non-zero because of existing decomposition and
  style debt across the large Dock/controller/runtime/store files and older
  policy/core files. This is maintenance work, not evidence of a failed
  behavior test; broad decomposition is intentionally deferred until after
  production behavior and release gates are complete.

## 2026-08-03 P1-A Sendable audit continuation

- Current `@unchecked Sendable` sites are limited to
  `MacClippySnippetLookupSnapshot`, `MacClippyPasteboardWriteSentinel`,
  `MacClippyDiagnosticsRecorder`, and `MacClippyRuntime`.
- The first three expose synchronous methods used by a CGEvent callback,
  pasteboard observer, and OSLog/diagnostics paths respectively. Each mutable
  field is protected by a private `NSLock`; replacing them with actors would
  force an async boundary into those callbacks. They should remain explicit
  lock-backed sendable reference types, with direct concurrency regression
  tests.
- `MacClippyRuntime` is different: it coordinates four GRDB stores, a shared
  `storeLock`, a dedicated capture queue, observer callbacks, OCR work, and
  UI reload callers. A broad actor conversion would change existing
  synchronous AppKit APIs. The safe incremental action is to test the current
  lock/queue ownership under concurrent calls and keep the annotation until a
  narrower store/coordinator split is available.
- The new boundary tests passed under Thread Sanitizer; this validates the
  tested lock-backed helpers and synchronous Runtime store path, but does not
  prove real CGEvent, TCC, Keychain, sleep/wake, or 24–72 hour behavior.

## 2026-08-03 Final implementation verification

- The review implementation is complete within `mac-clippy/`: pasteboard polling/lazy-provider retry, shared write sentinel, in-memory snippet lookup, retention/deletion journal, representation Blob cleanup, structured search, latest-wins reload behavior, paste lock narrowing, thumbnail/preview loading, privacy defaults, permission fallback, launch-at-login diagnostics, and recovery/diagnostics UX are implemented and covered by focused regressions.
- Final package verification: `swift test --package-path MacClippyKit` passed 199/199.
- Final app verification: scheme-qualified Debug arm64 App XCTest passed 121/121, 0 failed, 0 skipped. The suite includes batch deletion/pinning, text-only deletion replay, Runtime concurrency, structured search pagination, privacy settings, queue paste, transform, and picker interaction coverage.
- Final build verification: `xcodegen generate` and unsigned Debug arm64 app build passed. Xcode still reports the local CoreSimulator framework version mismatch; it does not block this macOS build.
- Scoped SwiftLint exits 2 on existing decomposition/style debt, including large `MacClippyDock`/`MacClippyRuntime`/`MacClippyDockController` types, complexity, line length, and identifier rules. This is recorded as maintenance debt rather than hidden with suppressions or a broad refactor.
- Remaining release evidence is external to these tests: Developer ID identity, signed Release archive, notarization/stapling/Gatekeeper, clean-user permission/TCC behavior, real pasteboard/provider/CGEvent/Keychain integration, and Instruments profiling with 100k records and 20–100MB images.

## 2026-08-03 P0-B follow-up: FTS degraded-state persistence

- Found a remaining integrity bug in `MacClippyRuntime`: after an FTS
  upsert succeeded, the runtime removed `fts-repair-needed`. That is unsafe
  because a prior failed upsert may have left older records missing from the
  index; an incremental success cannot prove a full repair.
- Removed the two incremental clears from capture and custom-label updates.
  The only production clear remains the transactional full
  `repairSearchIndex()` path.
- Added an App regression that marks the index degraded, performs a
  successful label/index write, verifies the search database remains
  `.repairable`, then verifies an explicit full repair returns it to
  `.healthy`.
- Focused App XCTest passed 1/1. A compiler warning from the test-only seam
  was corrected immediately by explicitly discarding the lock helper result.

## 2026-08-03 Startup health and shipping metadata follow-up

- Startup previously ran reconciliation and retention but did not emit a
  health result unless Settings was opened. `MacClippyRuntime.reconcileStorage`
  now runs the existing bounded `storageHealthLocked()` pass after recovery.
  Each non-healthy database produces a fixed `databaseHealthFailed` event with
  only the database name, repairability category, and safe recovery action;
  no SQLite error text, local path, or clipboard data is included.
- Added an App regression for a persisted `fts-repair-needed` marker. The
  test bundle compiles with the new runtime path, but the local Xcode runner
  again stops at `waiting for workers to materialize`; no assertion result is
  claimed for that test in this environment.
- Added `scripts/verify-build-metadata.sh`, which validates the shipping App's
  bundle identifier, APPL package type, menu-bar `LSUIElement`, required
  Accessibility/Input Monitoring usage descriptions, and executable. It is
  intentionally not a signature/notarization check.
- CI now compiles the shipping configuration unsigned and checks
  `ENABLE_HARDENED_RUNTIME=YES` plus the built App metadata. Developer ID,
  notarization, stapling, Gatekeeper, and clean-user TCC verification remain
  external release gates.

## 2026-08-03 P0-B cleanup failure propagation follow-up

- Static audit found that `MacClippyReconciliation.reconcile` used `try?` for
  orphan Blob and FTS deletion, while `MacClippyRuntime` could still emit
  `reconciliationCompleted`. This was a real observability/integrity gap:
  cleanup failures could remain on disk without a degraded state.
- The reconciliation result now carries failed Blob and FTS cleanup IDs. The
  sweep continues after one failure, but Runtime marks the corresponding
  storage area degraded, emits `reconciliationFailed`, and only emits the
  success event when all detected cleanup operations completed.
- `RetentionPolicy.enforceTotalCap` previously skipped any record whose
  footprint could not be decoded. It now propagates the error, so a corrupted
  record cannot be treated as zero bytes while claiming the total cap was
  enforced. A regression confirms the record remains present and the error is
  visible to the caller.
- Verification after the follow-up: Reconciliation 7/7, Input/Retention 4/4,
  full `MacClippyKit` 204/204, scheme-qualified App XCTest 123/123 with 0
  failures and 0 skips, Debug arm64 App build passed, App
  `build-for-testing` passed, and built App metadata validation passed.
- Scoped SwiftLint still reports the existing `MacClippyRuntime` size/
  complexity violations and older line-length warnings. No broad refactor was
  introduced for this integrity fix.

## 2026-08-03 隐私说明与最终回归

- 新增 `MacClippyPrivacyNotice`，把数据保存、删除、当前 build 网络边界、diagnostics 和 backup 的隐私范围明确展示在 Settings 中；这解决了实现已有隐私边界但用户不可见的问题。
- Settings 回归覆盖了删除范围和“当前 build 不主动联网”的说明边界。说明没有把加密 metadata/FTS 误表述成“所有内容都加密”，也没有把 diagnostics/backup 误表述成无条件安全。
- Package suite 最终为 204/204；unsigned Debug arm64 App build 与 `verify-build-metadata.sh` 均通过。
- 最新 clean DerivedData App XCTest 在 build/test bundle 阶段通过，执行阶段仍被 Xcode/LaunchServices 卡在 `waiting for workers to materialize`。这与此前已记录的 runner 环境阻塞一致；不把它当成产品失败，也不把它当成新的通过证据。
- 仍未完成的发布证据：Developer ID signed Release/archive、notarization/stapling/Gatekeeper、干净用户 TCC/Keychain/Accessibility/Input Monitoring、真实 NSPasteboard/provider/CGEvent integration，以及 Instruments 下 10 万条历史和 20–100MB 图片的 CPU/内存/能耗/soak 测量。

## 2026-08-03 Paste restore 与规模夹具 follow-up

- 发现 `MacClippyPasteInjector` 在原 clipboard 是 unavailable lazy provider 时，会把无法 materialize 的类型从 snapshot 中丢掉；若之后自动粘贴失败，恢复操作可能清空而无法还原该 item。这是 P1 data-loss 风险。
- 修复后，snapshot 记录 `isComplete`；只要任一原始 UTI 无法读取，injector 立即返回 `manualPasteRequired`，不会写入、清空或改变原 clipboard。新增 provider-unavailable 回归测试，5/5 通过。
- 增加 opt-in `MacClippyScaleTests`：100,000 条加密文本记录写入 clipboard + FTS 后验证单词搜索与 50 条分页；另验证 20 MiB representation spill、读取、删除和 Blob 回收。运行结果 2/2 通过，总耗时 28.214 秒。
- Scale fixture 默认不运行，避免普通 suite 隐式制造大型临时数据库；使用 `MACCLIPPY_RUN_SCALE_TESTS=1` 显式执行，测试输出不包含 fixture 正文。
- Release 配置编译仍被本地 deploy/release Guard 要求显式 deploy authorization；未绕过 Guard，也未把 unsigned Debug 结果当成 Release 证据。
- CI 已有 Release compile/Hardened Runtime/metadata step；本轮把 opt-in scale fixture 作为独立 CI step 纳入，避免只依赖开发机手工运行。

## 2026-08-03 Lifecycle pressure follow-up

- 不启用 parallel testing 的 App XCTest 仍在 `IDEInstallLocalMacWorker` / `LaunchServicesLauncher` 阶段停住，约 96.5 秒后中断，result bundle 没有生成有效 `Info.plist`；没有任何 `xctest` worker 进程，因此不是业务断言失败。
- 新增 opt-in `MacClippyLifecycleStressTests`，在 observer 的生产式 serial lifecycle queue 上执行 10,000 次 start → poll → stop，验证 timer、handler、retry state 和 sentinel cleanup 的重复生命周期。
- `MACCLIPPY_RUN_STRESS_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyLifecycleStressTests`：1/1 通过，耗时 0.186 秒。
- 最终普通 package suite：208/208 通过；scale/stress fixture 在未设置环境变量时不创建大型数据或启动压力循环。

## 2026-08-03 Signed artifact verifier follow-up

- `scripts/verify-signed.sh` 原先验证 Developer ID、TeamIdentifier 和 strict signature，但没有验证 hardened runtime flag；这会让一个没有 runtime protection 的签名包通过脚本。
- 现在强制 `codesign -dv --verbose=4` 输出包含 `flags=.*runtime`，并复用 `verify-build-metadata.sh` 检查 bundle identifier、APPL、`LSUIElement`、权限用途和 executable。
- `bash -n scripts/verify-signed.sh` 通过。真实 Developer ID、strict signature、Gatekeeper 和 notarization 仍需凭据/干净环境，未用 ad-hoc App 冒充这些证据。

## 2026-08-03 收尾复核

- 100,000 条加密历史 + FTS 搜索/分页规模夹具通过，耗时约 27.4 秒；20 MiB representation spill、读取、删除和 Blob 回收通过。
- Observer 10,000 次 start/poll/stop 生命周期压力夹具通过，耗时约 0.18 秒。
- Debug bundle metadata 已确认 `CFBundleIdentifier`、`APPL`、`LSUIElement`、Accessibility/Input Monitoring usage descriptions 和 executable；这是应用元数据证据，不是 Release 签名证据。
- App Store 规则复核未发现账号、IAP、广告追踪或网络服务代码信号；现有应用内隐私说明仍把正式公开 privacy-policy URL 留给产品 owner，因此没有用占位 URL 伪造提交合规。
- 针对核心变更文件运行 SwiftLint 发现既有 `MacClippyRuntime`、`MacClippyDock`、`ClipboardStore` 大文件/大类型，以及复杂度、标识符、长行问题；这些属于已记录的结构性维护债务，不作为本轮行为修复的理由进行大规模重构。

## 2026-08-03 implementation finding: paste metadata must not redefine paste success

- `MacClippyRuntime.paste(id:)` and transformed paste previously used a throwing
  frequency update immediately after `pasteInjector.inject` returned
  `.injected`. If the clipboard database became unavailable in that small
  window, the caller received an error even though the target application had
  already received the paste keystroke. Ordered/queued paths also used
  `try?`, making the same metadata failure invisible.
- The fix treats frequency as derived metadata: the injection result remains
  authoritative, while a failed counter write emits the stable diagnostic code
  `pasteMetadataUpdateFailed` with impact
  `paste_succeeded_frequency_not_updated`. This avoids both false failure and
  silent loss of observability without widening the paste lock.
- Regression fixture closes the runtime from the injector callback after the
  event is accepted. The test compiles in the app test target; execution is
  currently blocked by the local XCTest/LaunchServices worker startup hang.

## 2026-08-03 implementation finding: hotkey rollback must be truthful

- `MacClippyGlobalHotKey.update(to:)` attempted to re-register the previous
  shortcut with `try?`. If that rollback failed too, AppDelegate still posted a
  notification saying the previous shortcut was restored.
- The update now throws `registrationRollbackFailed` when the rollback cannot
  be completed, and the UI message tells the user to check Input Monitoring and
  retry. This keeps the hotkey state machine and user-facing state aligned.
- Package tests and ThreadSanitizer package tests both pass 209/209; the
  rollback's real Carbon/TCC behavior still requires a signed macOS integration
  environment.

## 2026-08-03 implementation finding: latency diagnostics were not wired

- The diagnostics event model already carried an optional duration, but the
  Runtime did not record successful capture/search/paste/reconciliation
  latency and diagnostics export had no aggregate view. That made the release
  requirement “有基本 latency 指标” unverified in code, even though the
  feature paths were tested.
- Added a bounded `operation -> {count,total,max,average}` aggregator protected
  by the existing synchronous diagnostics lock. Dynamic operation names are
  rejected when blank or longer than 64 characters, and the number of unique
  keys is capped by recorder capacity. Metrics contain no clipboard content.
- Instrumented the core runtime paths with monotonic uptime measurement and
  exported the aggregate under `metrics`. Added focused and concurrent
  regression coverage.
- Verification: package 213/213 passed; package ThreadSanitizer 213/213
  passed without a race report; Debug arm64 App/test `build-for-testing`
  passed; bundle metadata verifier passed.
- This evidence supports code-side observability only. It does not provide
  percentile distributions, CPU/memory/energy attribution, or real-system
  Instruments/soak evidence; those remain release prerequisites.

## 2026-08-03 final verification: instrumentation warning cleanup

- The first final App build reported an unnecessary `try` on the queued-paste
  diagnostics wrapper. The queued path catches its preparation failures and
  does not throw through that wrapper, so the `try` was removed as a surgical
  warning fix; no behavior change was intended.
- The subsequent Debug build and App test-bundle build succeeded. Bundle
  metadata validation passed for both artifacts.
- Package and Thread Sanitizer suites remained at 213/213 after the fix.
- The App XCTest runner was not reclassified as passing: the final pass only
  proves test-bundle compilation, while the local LaunchServices worker
  materialization blocker still prevents execution in this environment.

## 2026-08-03 finding: runtime lifecycle transition race

- `MacClippyRuntime.start()` used the store lock only to flip `running`, then
  installed the retention timer, UserDefaults observer, pasteboard observer,
  and Snippet event tap outside that transition. `stop()` could interleave in
  that window, leaving resources active after a stop had completed.
- Added a dedicated lifecycle lock to serialize the complete start/stop/permission
  refresh transition. It does not widen the database lock or hold a lock across
  capture/store work.
- Added a repeated start/stop idempotence regression in the App test target.
  The test bundle compiles successfully; execution remains blocked by the
  local LaunchServices XCTest worker issue.
- Package and Thread Sanitizer suites remain 213/213. This validates the
  package-side boundaries but does not replace real AppKit/TCC lifecycle
  testing.

## 2026-08-03 finding: explicit scale and lifecycle evidence

- The opt-in lifecycle pressure fixture passed 1/1: 10,000 observer
  start/poll/stop cycles completed in 0.172 seconds. This is evidence for the
  serialized observer lifecycle and idempotent transitions, not evidence for
  sleep/wake or long-running AppKit/TCC behavior.
- The opt-in scale fixture passed 2/2: 100,000 history records remained
  searchable and pageable in 27.560 seconds, and a 20 MiB representation
  spilled, read, deleted, and reclaimed its Blob successfully.
- These tests intentionally do not print clipboard bodies, OCR text, image
  bytes, or file paths. They still do not replace Instruments CPU/memory/
  energy sampling or a 24–72 hour soak.

## 2026-08-03 finding: privacy alert was presented too early

- The reported alert was created by `presentPrivacyNoticeIfNeeded()` during
  `applicationDidFinishLaunching`, and `runModal()` was entered before the
  menu-bar agent had returned to its normal event loop. On the affected build,
  the alert appeared but button clicks and Return did not dismiss it.
- `Open Settings` had a separate routing defect: it only called
  `MacClippySettingsWindowCoordinator.bringToFront()`. When no Settings window
  had been created yet, that method could only set a pending flag and could not
  instantiate the SwiftUI Settings scene.
- The fix defers the alert one main-queue turn and routes Settings through
  `showSettingsWindow:` before applying the coordinator focus step.

# Phase 5 isolated E2E, performance, and soak driver

This infrastructure uses the dedicated `MacClippyE2E` app target with the `MACCLIPPY_E2E` compilation flag and bundle identifier `com.macallyouneed.macclippy.e2e`. The shipping `MacClippy` target does not define that flag and does not include the E2E control entry points. The E2E target compiles the shared app sources plus isolated control helpers.

## Build the isolated app

```sh
xcodegen generate
DERIVED_DATA="$(mktemp -d -t macclippy-e2e-deriveddata)"
mkdir -p "$DERIVED_DATA"
BUILD_IDENTITY_JSON="$(python3 scripts/e2e/macclippy-phase5.py source-manifest --output "$DERIVED_DATA/source-manifest-before-build.json")"
SOURCE_CONTENT_SHA="$(printf '%s' "$BUILD_IDENTITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sourceContentSHA256"])')"
xcodebuild \
  -project MacClippy.xcodeproj \
  -scheme MacClippyE2E \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  MACCLIPPY_E2E_SOURCE_CONTENT_SHA256="$SOURCE_CONTENT_SHA" \
  CODE_SIGNING_ALLOWED=NO \
  build
APP="$DERIVED_DATA/Build/Products/Release/MacClippyE2E.app"
```

The E2E target uses the explicit `MacClippy/E2E-Info.plist`. It embeds the build configuration and `MACCLIPPY_E2E_SOURCE_CONTENT_SHA256` into the app's Info.plist. The driver recomputes the tracked/untracked build-input digest and rejects launch if it differs from the embedded digest. This binds the executable to the source snapshot used for that build.

The driver validates the bundle identifier and executable before launching. It uses the `NSWorkspace` launcher in `scripts/e2e/macclippy-e2e-launch.swift` with activation disabled and the app hidden. The E2E app uses accessory activation policy for background ingestion. Visible UI measurements explicitly unhide and activate it.

## Isolation rules

- The app requires `MACCLIPPY_E2E_ROOT` and a UUID `MACCLIPPY_E2E_RUN_ID`, plus its exact E2E bundle identifier. Missing or invalid settings terminate startup.
- E2E launch also accepts optional `MACCLIPPY_E2E_RETENTION_MAX_ITEMS`, a strict decimal integer from 1 through 200000. Missing retains the E2E 200000-item corpus/stress allowance; the soak runner explicitly launches with 10000. The driver overrides an inherited value for each launch, and the same-root marker preserves the requested value for controlled restarts.
- Before corpus or soak work, the driver compares effective `retentionMaxItems`, `retentionMaxImageBytes`, and `retentionMaxTotalBytes` metrics with the requested policy/model. Missing caps listed in `unavailableMetrics` remain unavailable and prevent workload startup; mismatched values fail before capture.
- `prepare` creates a new, empty, owner-only root in the OS temporary directory and writes the runner-owned marker. The app checks the marker, UID, restrictive permissions, resolved symlinks, OS temporary root, and overlap with the normal MacClippy Application Support root. A root lock prevents concurrent E2E app instances for one run.
- The root contains the four databases, encrypted blob and thumbnail stores, diagnostics journal, control socket, and a persistent disposable device key. The key is a root-local 32-byte file with mode `0600`; it is reused for the controlled process restart and is never read from or written to Keychain.
- E2E startup passes explicit paths, key backend, observer, paste injector, write sentinel, and per-run `UserDefaults` into Runtime, DockModel, and the Settings view. The Settings host installs the validated run-specific suite with `defaultAppStorage`; capture and privacy-pause settings therefore stay inside the disposable run. Hot-key construction/unregistration and launch-at-login changes are excluded from E2E, including failed-start and termination cleanup. Startup rejects a mismatched bundle ID/build flag before storage, key, or pasteboard setup. E2E-only initializers fail closed if dependencies are absent. The app stays accessory-only without a menu bar item during background runs; explicit visible UI commands activate only the E2E instance.
- Background capture and soak use a per-run named `NSPasteboard` and a fixed synthetic source-app identifier. The runner never reads or writes `.general`, the user's clipboard contents, real history, the user's Keychain, foreground-app identity, or installed `/Applications/MacClippy.app`.
- The injected paste path writes only to the named board. Its event callback inserts the prepared content into the `MacClippyE2ERecipient` in-memory test double, and the driver verifies inserted text, types, byte count, and hash. It does not post Cmd+V or use OSAX. Results label this internal recipient explicitly; they are not evidence that TextEdit, Safari, Terminal, or Finder accepted content.
- Snippet expansion/event tap, Carbon global shortcut registration, launch-at-login startup registration, and privacy prompts are disabled for the E2E build. The launch-at-login Settings action is also disabled under E2E. No privacy permissions are changed.
- The requested real `.general` interoperability remains Phase 6 of this same request. It must be separately coordinated with an explicit capture pause in the installed product and must not be added to background soak. Phase 5 automation does not touch `.general`.

`MacClippyUITests` targets the distinct E2E bundle and requires an explicitly prepared marked root. Ordinary automated tests must select `-only-testing:MacClippyTests`; do not run the unrestricted scheme test action because it includes the UI test target and launches an app. The bounded Phase 5 smoke uses only the authenticated E2E control channel and synthetic recipient.

## Native GUI acceptance with Cua

Use one Cua owner and one isolated app instance at a time. Do not run a windowed XCTest host concurrently with native acceptance. For native acceptance, request `native-host-show` before `panel-show`. This opt-in window mirrors only the isolated in-memory recipient and keeps an AX target available when the Dock closes; it never reads `.general` and is absent from background/soak runs. Use `native-host-hide` after acceptance. Prepare synthetic records through the authenticated control socket, wait for `panel-show` to report an interactive panel, then bind `com.macallyouneed.macclippy.e2e` in Cua. If the current window exposes `Raise`, invoke that observed secondary action before input. Refresh the AX tree after each menu or popover action; selecting a type closes the filter popover immediately, so its previous Apply element is no longer valid.

For appearance reviews, `request --control-command appearance-set --text light|dark|system` overrides only the isolated app's `NSApp.appearance`; it does not change macOS preferences. `surface-show --text preview|details|edit|pinboard|settings` opens the production surface using isolated records (a visible panel is required except for settings). The response acknowledges the request, not asynchronous content readiness. These setup commands do not prove native menu or keyboard activation; verify rendering and native flows separately. Non-key previews and popovers may not be included in a focus-window screenshot.


Cua error `-10005` alone does not establish a hung application or a locked screen. Distinguish `timeoutReached` from a stale element ID, check `metrics.panelReadiness`, and inspect the bounded run-local `e2e-diagnostics.jsonl` focus events. Those events include visibility handoffs, window/pointer geometry, mode, and the owned application’s activation state, with no clipboard text or another application’s identity. An internal Details window becoming key must keep the Dock open even when an AX action leaves the pointer outside both surfaces. A queued resign-key notification must not dismiss a Dock that has already regained key. Actual outside clicks still dismiss through the local/global click monitors. If an AX action replaces or closes its target and returns an error, inspect the new tree before retrying the action. The help window uses one native selectable text document so its content remains readable without nested SwiftUI GroupBox/row traversal.

If Cua reports `native pipe closed before response` after an owned app restart while its authenticated control endpoint still responds, reset the Cua REPL, refresh the surface inventory with one documented entry call, then bind the exact verified E2E app path. Recheck the PID, run root and source digest before continuing. Record a recovered connection separately from an application crash, and inspect the current UI before retrying any action that might already have completed.

Acceptance must use native menus, editors, keyboard events, and a real input method candidate confirmation. When VoiceOver is in scope, run its native navigation separately. Control-channel `search-ui`, model calls, synthetic `setMarkedText`, and exposed AX custom actions are useful setup or checks, but do not prove all of those user flows. Record the initial input source and any accessibility settings that the requested acceptance changes, restore temporary changes afterward, and report any remaining native coverage separately. Paste delivery in this target remains the named-pasteboard/in-memory recipient described above.

## Prepare a run root and launch

```sh
DRIVER="scripts/e2e/macclippy-phase5.py"
PREPARE_JSON="$(python3 "$DRIVER" prepare)"
ROOT="$(printf '%s' "$PREPARE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
RUN_ID="$(printf '%s' "$PREPARE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["runID"])')"

python3 "$DRIVER" start --app "$APP" --root "$ROOT" --run-id "$RUN_ID"
```

`start` returns the app PID and leaves the process available through the run-scoped Unix socket after the CLI exits. The app accepts only a socket beneath its marked root. The same root and run ID are required for later commands.

`prepare` records the default 200000-item E2E allowance in the owner-only root marker. `start`, corpus setup, and performance runs launch with that value explicitly, regardless of an ambient shell variable. `restart-check` rereads the marker and requires the same effective item and byte caps after restarting the app.

## Capture, restart, and interaction examples

Capture writes a selected primary type through the named board, requests or awaits a read through the production pasteboard observer, waits for a new stable Runtime history identity, and decrypts the saved raw representation to verify its byte-level round trip. Responses keep the requested `sourceFormat` separate from the observed `primaryContentKind`: for example, AppKit may publish a plain-text primary for an RTF source while retaining the published `public.rtf` bytes as an encrypted representation. The raw-byte assertion compares the bytes published on the named pasteboard with the saved representation, not an in-memory fixture before AppKit publication. `--ingestion-mode forced-poll` labels an immediate production observer read; `natural-poll` labels ordinary observer cadence. Corpus setup uses forced reads and reports that separately from natural-poll capture; neither mode inserts database rows directly.

```sh
python3 "$DRIVER" capture \
  --root "$ROOT" --run-id "$RUN_ID" \
  --token phase5text01 --format text \
  --text 'phase5text01 synthetic capture'
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command search-db --query phase5text01
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command search-ui --query phase5text01
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command panel-hide
```

Normal and plain-text paste use the visible Dock controller key action and the Runtime paste injector. The recipient is intentionally synthetic and isolated. Each successful paste must report the process-targeted route to the current E2E PID; the runner rejects the global fallback route, missing insertion, or an OSAX event. Both injected poster callbacks terminate at the in-memory recipient, so these checks do not post system keystrokes:

```sh
python3 "$DRIVER" capture \
  --root "$ROOT" --run-id "$RUN_ID" \
  --token phase5html01 --format html \
  --text '<html><body><p>phase5html01 styled fixture</p></body></html>'
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command paste --query phase5html01
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command paste --query phase5html01 --plain
```

For a real preview presentation/load/close loop, `preview-loop` searches for the fixture and waits for each preview's content load, visible presentation, and close. Cancellation selects a visible record, invokes production `Runtime.paste` with the production injection gate, blocks the isolated trust-check hook, closes the gate, and awaits the operation's `.cancelled` result before reporting success. The completed result and zero in-memory recipient insertions are checked; it does not claim real-app or OSAX delivery.

```sh
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command preview-loop --query phase5text01 --cycles 10
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command recipient-reset
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command paste-begin-cancelable --query phase5html01 --rich
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command paste-barrier-status
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command paste-cancel
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" \
  --control-command paste-barrier-status
```

The encrypted restart check creates a synthetic 65,536-byte text record, requires an authenticated spilled-representation proof, terminates the app, launches the same E2E app against the same root/key, then verifies the same stable record ID and decrypts the spilled representation again:

```sh
python3 "$DRIVER" restart-check --app "$APP" --root "$ROOT" --run-id "$RUN_ID"
```

Use `python3 "$DRIVER" request --help` to see the socket commands. `search-ui`, `panel-show`, `preview-loop`, and `paste` explicitly activate the E2E app. Background capture, corpus creation, and soak do not.

## Reproducible corpora

`corpus` supports 1,000, 10,000, and 100,000 records; the product-default fixture size is 10,000. It defaults to seed `20260925`. Indices 0–13 and the full-scan tail positions are fixed; all other positions use the seeded 68/12/10/5/5 text/HTML/RTF/image/files distribution. Image and file entries are actual primary image and file records. File fixtures are disposable files under the marked root, with declared bytes recorded. Every 37th item repeats its primary UTI on a second pasteboard item; every 257th item also has two items. The seed, actual content-kind distribution, item counts, repeated UTI count, source bytes, observed pasteboard bytes, primary payload bytes, fixture-file bytes, per-capture raw samples, and progress file are written under the fixture root. Fixed text edge fixtures include CJK plus emoji, combining marks plus variation selectors, bidirectional marks, U+FFFC, and 65,536-character text. Image/file identity is checked by stable captured record identity and payload kind; asynchronous OCR is not required for that identity check.

Each scale validates common hit, rare old hit, zero hit, CJK substring tail, ASCII infix and prefix tails, structured type filters, and combined type/app filters against deterministic count and stable-ID contracts. Search terms and filter syntax follow the production parser. Tail-only queries require their tail record IDs, so frequent recent matches cannot make a limit-16 page appear to cover the full-scan tail. A successful run writes one summary group per query class, with database/runtime-only and visible UI results kept separate; app-operation, control-socket, driver, and estimated IPC/driver overhead timings remain distinct.

```sh
python3 "$DRIVER" corpus --app "$APP" --root "$ROOT" --run-id "$RUN_ID" --count 1000 --seed 20260925
python3 "$DRIVER" corpus --app "$APP" --root "$ROOT" --run-id "$RUN_ID" --count 10000 --seed 20260925
python3 "$DRIVER" corpus --app "$APP" --root "$ROOT" --run-id "$RUN_ID" --count 100000 --seed 20260925
```

The corpus runner uses the 200000-item E2E allowance so the 100000-record fixture is not evicted during setup, and verifies all effective item/image/total-byte caps before capture. A fresh 100k run can launch and build the fixture in one command:

```sh
python3 "$DRIVER" corpus --app "$APP" --count 100000 --seed 20260925
```

The 100k case is a large real production-ingestion workload and may take substantial setup time. There is no per-record 400 ms sleep. Ingestion wall time, post-ingestion quiescence, query-contract verification wall time, and total setup wall time are separate from benchmark samples. Quiescence requires three consecutive 100 ms samples with capture queue depth and bytes at zero; OCR completion is reported but is not an identity or indexing prerequisite. If 100k controlled ingestion is slow, keep the measured wall time and do not replace it with direct database seeding.

## Release performance run

The runner requires an explicit `--interactive` opt-in because visible search, panel, paste, and preview tasks activate the isolated app. It records database-only search separately from visible app search and panel interactivity. App UI latency ends after the panel is a key window, initial content is painted, the foreground is visibly rendered, and AppKit layout/display have been flushed; preview cycles await loaded content and visible presentation/close state. Driver, socket, app-operation, app-metrics, and exact-process sampler durations are retained separately.

```sh
python3 "$DRIVER" benchmark --app "$APP" --count 10000 --seed 20260925 \
  --iterations 30 --preview-cycles 10 --build-configuration Release --interactive
```

The runner writes a result directory under the marked root containing:

- `source-manifest.json`: base commit, a sorted tracked/untracked build-input list, per-file SHA-256 and size, source-content digest, and manifest digest. Generated reports and raw result files are excluded.
- `environment.json`: OS/build, Xcode, hardware model/architecture/CPU/memory where available, Release configuration, E2E bundle identity, base commit, source digest, working-tree state, executable SHA-256, and requested/effective retention policies.
- `corpus-metadata.json`, `samples.jsonl`, and `resource-samples.jsonl`: seed/distribution/payload bytes, per-task raw timings, process baseline/after-task/end metrics, and app queue/WAL snapshots.
- `summary.json`: observed p50/p95/p99 by task and target thresholds in separate fields.

Targets are warm panel interactive p95 at or below 100 ms, 10k visible app search p95 at or below 100 ms, and 100k visible app search p95 at or below 200 ms. DB-only search p95 is reported separately and never substituted for visible UI latency. The benchmark also exercises normal/plain paste, cancellation, a controlled 250 ms SQLite write lock, adversarial Unicode searches, and awaited preview loops.

The preview loop uses a finite workload-aware control-socket timeout: `max(120, 45 + ceil(cycles × 0.65))` seconds after clamping requests to 1–1,000 cycles. This budget covers existing content readiness, visible presentation, and close animation for every requested cycle; animation remains enabled. The driver passes the same normalized cycle count to the app and rejects any response whose completed count differs, whose content is not ready, or whose presentation remains visible. At 1,000 cycles the socket timeout is 695 seconds.

The typed helper `macclippy-e2e-rusage.c` verifies the exact isolated PID executable before reading `proc_pid_rusage` with `rusage_info_v4`. It reports RSS and physical footprint separately, user/system CPU counters, interrupt/package wakeups, process I/O bytes written, and monotonic clocks. XNU Recount documents CPU usage time as Mach time units, and `fill_task_rusage` copies its task user/system counters into `ri_user_time` and `ri_system_time`; the runner converts them with the returned `mach_timebase_info` fraction. See [XNU `recount.md`](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md), [XNU `bsd_kern.c`](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c), and [Apple `mach_timebase_info`](https://developer.apple.com/documentation/kernel/mach_timebase_info).

Whole-device writes and maintenance queue depth are unavailable and are recorded as unavailable. A zero rusage process-write counter is marked unknown-or-unavailable, not as zero work. Absent WAL files are reported as zero bytes; file attribute failures are null/unavailable. CPU deltas, wakeup deltas, and write deltas/rates include units. The process sampler spawns a typed helper at baseline, after each measured task, and end of run; each helper duration is recorded outside the app-operation latency. Per-task app metric collection time and the separate app-only baseline are also retained.

## Durable mixed-load soak

The soak command creates a new marked root, detaches a worker into its own session, and launches an owned E2E app with `MACCLIPPY_E2E_RETENTION_MAX_ITEMS=10000` before mixed synthetic named-board capture and FTS search. It verifies all three effective Runtime retention metrics before the first workload operation. If an already running app is found on that root, the worker checks its actual policy and fails before workload; it never changes policy or restarts an app it does not own. The requested policy is recorded in the root marker; requested and effective policies are recorded in runner owner/status files, soak metadata, and the app-process record. The workload rotates text, HTML, RTF, image, and file fixtures, including one-, two-, and four-item boards and repeated primary UTIs across items. It does not use the general clipboard, activate UI, read foreground-app identity, or change sleep settings. Each successful capture must return a stable record ID, actual primary kind, and ordered per-item raw UTI/payload proofs; the driver then calls `verify-record` by that ID and searches the current primary-kind population. RTF source format stays separate from the observed primary kind (which can be `text`). Decoded text is checked for text-backed primary records; non-text records must report decoded text as null, so image search does not assume OCR.

Expected type-search counts follow the verified Runtime policy: 10,000 items, no age limit by default, image payload cap `retentionMaxImageBytes` (2,048 MiB), total database/blob cap `retentionMaxTotalBytes` (4,096 MiB), and at most 512 search rows. The ledger uses the captured item/image/total-byte caps, records authenticated raw representation bytes only as lower bounds, and requires an exact real type-search count after every capture. If retention eviction changes the expected rows, the assertion fails. The fresh record ID must remain in the bounded result.

Idle-app-only metrics establish the baseline for available counters `captureQueueDroppedChangeCount`, `captureQueueRecoveredChangeCount`, `captureQueueHasUnrecoveredChanges`, `captureNotSavedCount`, `capturePersistFailureCount`, `captureQueueOverloadErrorCount`, and `captureQueueCurrentGenerationReadRequestCount`. Samples compare against it and fail on new dropped changes, unsaved captures, persistence failures, overload errors, or unrecovered changes. The worker records queue and OCR depth/bytes, all available counters, WAL sizes, the `unavailableMetrics` list, and a final product-metrics snapshot before app termination. Missing fields stay null/unavailable, never zero. Raw capture, verify-record, and search responses are kept in JSONL evidence. The local app control channel is event-driven; the worker's scheduled workload/metric wake checks extension requests without a busy loop.

```sh
SOAK_JSON="$(python3 "$DRIVER" soak start --app "$APP" --hours 24)"
SOAK_ROOT="$(printf '%s' "$SOAK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"])')"
SOAK_ID="$(printf '%s' "$SOAK_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["runID"])')"
python3 "$DRIVER" soak status --root "$SOAK_ROOT" --run-id "$SOAK_ID"
```

Run `soak start` directly from a fresh invocation; it creates the root, requests the 10000-item launch policy, and checks effective Runtime telemetry before returning. Do not start an app first and point a soak at a process with unknown policy. The start response and later status include requested and effective retention policy.

To continue a still-running 24-hour run to 72 hours, request an additional 48 active-coverage hours before it completes. A 72-hour run can also be started directly. `soak extend` publishes one private pending request and returns its request ID; it does not claim the hours are accepted. The active worker serializes consumption, validates a non-symlink owner-only regular file, UID, canonical root, run ID, owner PID, UUID request ID, and a positive integer hour count, then checks that the total target will not exceed 72 active hours. Acceptance appears in `acceptedExtensionRequestIDs` and a `soak-extension` sample. Invalid or replayed requests leave the previous target unchanged and produce `lastExtensionRejection` plus an `extension-rejected` sample; simultaneous publishers cannot replace a pending request. Stop writes a similarly owner/run-checked request into the marked root; the worker observes it and terminates only its own E2E app through the authenticated control socket. The runner never signals a recorded PID. Clean validates the owner-only root marker, confirms the app instance and runner locks are clear, atomically moves the root into a quarantine name, rechecks the marker and symlinks, then removes only that root.

```sh
python3 "$DRIVER" soak extend --root "$SOAK_ROOT" --run-id "$SOAK_ID" --hours 48
python3 "$DRIVER" soak stop --root "$SOAK_ROOT" --run-id "$SOAK_ID"
python3 "$DRIVER" soak clean --root "$SOAK_ROOT" --run-id "$SOAK_ID"
```

Validate the detached runner with a bounded smoke run once the shared build lane is released:

```sh
python3 "$DRIVER" soak start --app "$APP" --smoke-seconds 30
```

The smoke run is runner validation only. The offline Python subprocess regression uses an accelerated simulated clock to verify request acceptance, replay rejection, and stop handling; it is a control-flow test, not an app run or a 24-hour/72-hour soak. Neither substitutes for a full soak. Soak active coverage uses awake Mach absolute-time deltas; `mach_continuous_time` minus awake time records suspected sleep gaps, and wall/monotonic coverage gaps are separately recorded. Apple documents that `mach_absolute_time` stops during sleep and `mach_continuous_time` continues, so sleep time and unobserved gaps do not count as active load. See [Apple `mach_absolute_time`](https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time) and [Apple `mach_continuous_time`](https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time). Samples also separate the initial idle-app-only baseline from mixed workload.

## Structured output fields

The JSONL files use one compact JSON object per line, each with `schemaVersion`, `recordType`, wall UTC and/or monotonic timestamp, plus the task fields below:

- Corpus samples: `production_observer_capture_and_index`, `adversarial_fixture`, and `corpus_ingestion_queue_and_storage_sample`. Capture rows include token, record ID, synthetic source app, format/types, input and observed pasteboard byte sizes, raw UTI/hash/bytes, round-trip result, and driver/socket timings.
- Performance samples: `db_only_search`, `visible_app_search`, `visible_app_search_adversarial`, `warm_panel_interactive`, `normal_paste`, `plain_paste`, `paste_cancellation`, `controlled_storage_delay_capture`, `preview_presentation_and_load`, and panel hide. Each retains app-operation, control-socket, driver elapsed, estimated IPC/driver overhead when measurable, response state, and queue/WAL snapshot.
- Process resource rows: exact runtime PID and executable; baseline, after-task, and end-of-run snapshots; RSS bytes; physical-footprint bytes; CPU cumulative values and deltas in Mach ticks and converted nanoseconds; interrupt/package wakeup cumulative counts, deltas, and rates; process I/O bytes written and rate where available; Mach awake/continuous timestamps; sampler elapsed time; and explicit availability fields.
- App metrics: effective `retentionMaxItems`, `retentionMaxImageBytes`, and `retentionMaxTotalBytes`, capture queue depth/estimated retained bytes, OCR depth/bytes, maintenance queue depth (listed in `unavailableMetrics`), and clipboard/search/pinboard/snippet WAL byte sizes. WAL attribute failures are listed as unavailable; a missing WAL file is zero bytes.
- Soak rows: `liveness`, `resource-metrics`, `workload`, `workload-capture-rejected`, `workload-verify-rejected`, `workload-search-rejected`, `controlled-storage-delay`, `soak-extension`, `extension-rejected`, and runner error records. Workload rows preserve raw capture/verify/search responses and the retained-window model, including raw responses when validation fails. Resource rows preserve raw app metrics, selected idle baseline counter values, counter deltas, unavailable fields, and final pre-termination metrics. Metadata, owner, and status files retain requested/effective retention policies, runner/runtime PIDs, target/covered active seconds, wall elapsed seconds, retention counts/byte lower bounds, cycles, samples, sleep-gap count, and last error.

## Cleanup and prerequisites

Terminate a manually started app through the socket and remove only the marked temporary root:

```sh
python3 "$DRIVER" request --root "$ROOT" --run-id "$RUN_ID" --control-command terminate
python3 "$DRIVER" soak clean --root "$ROOT" --run-id "$RUN_ID"
```

The second command is named `soak clean` because root cleanup is grouped with soak lifecycle commands; it works for any marked run root. It refuses active app/worker locks. Do not point it at a path you did not obtain from `prepare` or the runner.

The isolated Release target was built and launched for the hidden smoke with source digest `af4e8081e350349b0e8aa71ee180b003f06eaac94e8e1d855012aa56de3a083a`. The hidden named-board smoke completed text, HTML, RTF, image, file URL, and repeated-UTI captures, verified encrypted RTF/HTML representations after a process restart, and checked that two image fixtures with formerly colliding short color encodings now yield distinct record IDs and payload hashes. After that smoke, structural-only source/test splits were made to satisfy the pinned SwiftLint gate. The final source-bound Release target was rebuilt successfully with digest `24cdd86ab8febb30814a72670f85ab3534fe41fca2c311a4a8e604edec1e0b18`; its build logs are `/tmp/macclippy-phase5-e2e-release-structural-final.stdout.log` and `.stderr.log`. The hidden runtime smoke was not rerun after those structural-only changes.

A bounded 30-second detached soak completed six capture/search cycles with seven available exact-process resource samples and no reported errors; this is runner validation, not 24-hour or 72-hour soak evidence. Its disposable root was cleaned after completion before the full sample JSONL and manifest were copied, so those raw files are not retained. Status and command logs remain under `/tmp/macclippy-phase5-e2e-final5-*`.

Visible panel, recipient-paste, cancellation, and preview-loop checks remain pending. The first visible panel request timed out because the host session was locked: the E2E app was not active, `com.apple.loginwindow` was frontmost, and the E2E panel window was onscreen but could not become interactive. The locked session was left unchanged. Do not count these UI checks as either pass or product failure; rerun them on an unlocked desktop session. The Release benchmark and the 100k visible search benchmark have not been run. macOS 14 runtime acceptance was explicitly not run. Real `.general` interoperability remains the separately coordinated Phase 6 work item in this request.

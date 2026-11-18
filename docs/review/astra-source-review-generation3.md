**RELEASE BLOCKED — generation 3. New confirmed findings: P0=0, P1=1, P2=1, P3=0.**

Independent reviewer: Astra. Review date: 2026-09-26 UTC. This is a **P1 stop report, not a completed full-source approval**. The isolated Release E2E app exited after a client closed an incomplete request. Product execution stopped once that P1 was confirmed; no frozen product source, tests, project settings, scripts, or earlier evidence was changed. Remediation is handed back to root for **gpt-6-luna/max**. The requested complete semantic review and post-restart E2E acceptance remain incomplete.

**Identity and inventory**

The first action read `/tmp/macclippy-phase6-control.json`. Independent assertions confirmed revision **49**, generation **3**, both mutation flags false, branch `codex/core-reliability-hardening`, and HEAD/base `79e987a982f15f9193392c9af98b66465efd5ee2`. Control SHA-256: `8bf0100dac134261b5febdb9cc5175c6cce98edb8c4083af736042d16d782763`.

The independent scanner re-enumerated git tracked plus nonignored untracked files, applied the manifest suffix/exclusion rules, reread every selected file, and hashed the sorted compact JSON entries array. It did **not** use the driver's manifest function to establish the independent result. All **518** entries match:

`e128200af9fe73bd5c3e29e69dcd7605a13dae21bc889ad1deeaa3d810fe3e5e`

The authoritative manifest and evidence copy are byte-identical; their file SHA is `3eef70be92c8b77fe8a623a0c54cc5162efce84c1af2475ef9e5df3c3b339089`. Twelve Release before/after/final manifests independently recompute to the same entries/digest. Initial inventory is **112 tracked changes + 156 untracked paths = 268**; **253** are changed build inputs. The other 15 are two READMEs, five engineering/user documents, six previous review reports, and two preexisting Python cache files. The staging area is empty. These counts include files outside Swift source and are not test counts.

Evidence and repeatable commands:

- [verify-identity.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/verify-identity.py); `python3 -B /Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/verify-identity.py start` (final invocation uses `final`).
- [identity-start.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/identity-start.json), [independent-manifest-start.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/independent-manifest-start.json), [inventory-start.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/inventory-start.json).
- Full tracked diff against the requested base: [tracked-full.diff](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/tracked-full.diff). Complete changed/untracked path enumeration is appended below. Capturing/hash-checking a diff is not a claim that every line received semantic review before the stop.
- Generation-2→3 delta: [generation2-to-3-input-delta.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/generation2-to-3-input-delta.json): nine paths, including the three new socket/thumbnail source/test files. All other selected build-input bytes match generation 2.

**P1 — E2E-G3-P1-001: disconnected control client can terminate the Release E2E process**

Status: **OPEN; blocks acceptance**. Newly identified in this review; no claim that every contributing line was introduced in generation 3. Scope is the E2E control server, not a demonstrated Shipping clipboard crash.

Locations: [accepted socket setup](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:334), [invalid-request response](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:349), [response write](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:383), [send call](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyUnixSocketLineTransport.swift:64).

Actual Release observation: owned PID **55199**, root `/private/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/mce5-d431d05i`, run UUID `99d33aea-c60b-4a43-9ba5-0072f013ac66`, exact frozen executable SHA `0037effa3eff297428327fdbed547eeb2c589b5c80e793a7c991b6fc7f89baf5`. At **07:43:20.658 UTC**, the client connected, sent the 11 bytes `{"command":`, then closed. The next authenticated `ping` received an empty response and failed at 07:43:20.707. The private instance lock was released. Later `ps -p 54683,55199 -o pid=,comm=` found neither owned PID. No terminate command or external signal preceded PID 55199's exit. The planned eight-repeat sequence was never reached; **one actual app peer-close failure** was observed.

Source mechanism: `setsockopt(SO_NOSIGPIPE)` return is ignored. A disconnected accepted socket can therefore proceed without signal suppression; EOF/incomplete JSON leads to an attempted error response. A standalone child compiled with the **unchanged production transport file** independently observed `setsockopt=-1, errno=22 (EINVAL)`, then exited with `returncode=-13 (SIGPIPE)` on `writeLine`. This supports SIGPIPE as the explanation for the app exit. **The actual app's termination signal/crash-report field was not collected**; it is an inference corroborated by source and the separate helper, not mislabeled as direct app signal telemetry.

Evidence:

- [actual peer-close, failure and cleanup timeline](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/runtime.jsonl:46); [result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/result.json).
- Exact actual-app execution input: [run-independent-e2e-normal-buffer.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run-independent-e2e-normal-buffer.py:77).
- [peer-closed-option-diagnostic.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/peer-closed-option-diagnostic.json); [socket-probe-option.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe-option.swift); [socket-probe-results-v2.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe-results-v2.json).
- [independent-cleanup-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/independent-cleanup-audit.json); [p1-stop-record.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/p1-stop-record.json); [finding-source-identity.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/finding-source-identity.json).

Remediation boundary: fail closed when per-socket SIGPIPE protection cannot be installed, without writing to that unprotected descriptor; preserve bounded read/write/cleanup. Add a real accepted-socket close-before/around-setup regression and error-response coverage. The current three socket XCTest methods exercise production **reads** (fragmentation, limits, deadline), but no write-error or accepted-descriptor setup failure. They are useful tests, not proof of this missing boundary. No source fix was made here.

**P2 — E2E-G3-P2-001: draining small-buffer peer receives a truncated response**

Status: **OPEN**, bounded E2E transport edge case. The normal driver does not set this small buffer. This is not a claim of Shipping data corruption.

Locations: [would-block write readiness](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyUnixSocketLineTransport.swift:75), [POLLOUT wait](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyUnixSocketLineTransport.swift:114).

First actual Release run, PID **54683**: ten captures and the exact fragmented 65,536-byte request passed. A `verify-record` reply containing the 65,536-byte decoded text was then read by a client with `SO_RCVBUF=1024`, after a 250 ms delay. The reply ended without complete JSON at approximately the server's 10-second write deadline. The exception is preserved; the first harness did not retain the complete truncated response bytes, which limits that raw observation.

Independent production-helper experiment supplied the missing byte count: sending 65,536 `W` bytes plus newline, a 0.7-second deadline, receiver buffer 1024 and observed sender low-water 2048 produced **8,192 bytes, no newline, false at 0.702403375 s**, despite a draining client. Default 8192 and requested 2048/4096/8192 receive buffers each produced **65,537 bytes and true**. The second actual app run using the normal receive buffer delivered a complete **66,183-byte** verification response after the same 250 ms read delay. Readiness/low-water interaction is the supported explanation; no kernel tracing was performed.

Evidence: [result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/result.json), [runtime.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/runtime.jsonl:37), [socket-probe-results-v2.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/socket-probe-results-v2.json), [run-socket-probes-v2.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run-socket-probes-v2.py), [runtime.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/run2/runtime.jsonl:39). Keep one monotonic deadline while making partial-send progress robust to this peer configuration; add write/backpressure tests. The app stayed alive in this first run and was shut down through its authenticated control socket in **0.174067125 s**.

**Generation-2 findings and earlier dispositions**

The previous source/E2E reports and historical finding dispositions were reviewed as predecessor material. Their raw metadata failure, Darwin fragment probe, stale-thumbnail probe, failed E2E trace, and Luna generation-3 smoke were read and hashed in [prior-finding-raw-evidence.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/prior-finding-raw-evidence.json). Luna's smoke remains predecessor evidence; it is not this reviewer's restart pass.

| Prior ID | Generation-3 disposition in this review |
|---|---|
| ASR-G2-P1-001 — plist versions | **Specified defect closed independently.** Plist values reference Xcode version settings; the unchanged metadata validator passed against all five actual Release bundles, including both override bundles. |
| E2E-G2-P1-001 — segmented nonblocking request read | **Specified read defect closed independently.** Both new app runs captured exact 65,536-byte text; both accepted a complete 65,536-byte framed request split at 29/1024/8192-byte stages. Direct production-helper read met three deterministic would-block boundaries. Overall control acceptance remains blocked by the new P1/P2. |
| ASR-G2-P2-001 — stale thumbnail waiter | **Specified source defect closed; regression log verified, not rerun here.** Cancellation closures capture originating Flight; release requires matching Flight and a removed waiter before decrement. The new test drives the actual loader through reset/new same-key work/stale release, old late-result rejection, and new delivery/cache. Focused log line443 and full App line4601 pass. |
| ASR-P1-001 — genuine old-schema backup | Generation-2 independent closure retained as predecessor status; generation-3 implementation/tests are byte-identical. Current KeyValidation's schema-aware roster/item-index handling and validate→stage/migrate→journal/install→Runtime reopen/finalize chain were read. The historical fixture was not rerun or fully rereviewed before stop. |
| ASR-P1-002 — paste owned generation/final slow AX | Generation-2 independent closure retained, code/test bytes unchanged. Complete injector/snippet chain rereview **incomplete in this pass**; no new real-event proof. |
| ASR-P1-003 — spilled payload proof | **Bounded actual capture proof now independently passes:** spilled 65,536-byte representation hash/length equals source and independent named-board read in both runs. Reopen still NOT RUN here. |
| ASR-P1-004 — soak extension consumption | Generation-2 independent closure retained, driver/tests unchanged; raw offline suite 37/OK checked. No worker rerun or 24h/72h soak here. |
| ASR-P1-005 — deferred replay owner/tap lifetime | Generation-2 independent closure retained, implementation/test bytes unchanged. Current App startup/stop/restore owners read; full expander/native lifecycle rereview incomplete. |
| ASR-P2-001 — accumulated promised-item retries | Generation-2 independent closure retained, unchanged implementation/tests. Current production reader's generation fences and item-index/UTI merging read; complete observer retry-chain rereview incomplete. |
| ASR-P2-002 — UTF-16 caret/decoder | Generation-2 independent closure retained, unchanged implementation/tests; no current synthetic CGEvent rerun or full decoder rereview. |
| ASR-P2-003 — stale queued callbacks | Generation-2 independent closure retained, unchanged implementation/tests; full Dock callback-chain rereview incomplete. |
| ASR-P2-004 — preview timeout | Generation-2 independent closure retained, unchanged driver/tests; budget constants inspected. Actual preview cycles NOT RUN. |
| ASR-P2-005 — details item identity | Generation-2 independent closure retained, unchanged model/tests; complete details-chain rereview incomplete. |
| ASR-P2-006 — staging path deletion guard | Generation-2 independent closure retained, unchanged script/tests; raw 8-point guard log checked. Packaging was not executed. |

These predecessor closures are explicitly **not a substitute for the requested complete fresh semantic review**. The control record's historical OPEN strings do not override later evidence, and a matching file hash is not new execution evidence.

**Review coverage at the stop**

Completed: full path/content identity and inventory; metadata/build artifacts; current card-loader fix and production regression; control server/transport/read-write error paths; E2E isolation/keychain/launch/termination; named-board capture/proof/search command routes; Runtime storage bootstrap; App startup/restore ownership; backup validation/key validation/restore journal implementation; portions of native reading/blob storage; predecessor reports and raw gates. Non-UI replay test assertions and the preparer were also inspected during evidence consolidation.

Incomplete: full working-tree semantic diff review; complete capture admission/queue/OCR cancellation chains; storage/index/blob deletion/locking and migrations; injector/snippet recipient binding/deferred teardown; file-thumbnail scheduler and remaining card lifecycle interleavings; release/CI scripts beyond inspected metadata/project/launch routes; full new/changed tests and documents. No broad crash-, race-, migration-, or data-loss-free conclusion is made.

**Raw gates and Release artifacts**

[raw-log-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/raw-log-audit.json) lists absolute paths, SHA-256, each XCTest terminal event with line number, and exact totals. These are **existing Luna-run logs independently parsed**, not suites rerun by this reviewer.

| Gate | Executed | Passed | Skipped | Failed tests |
|---|---:|---:|---:|---:|
| Package full (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/package-full-final.log:1638`) | 643 | 639 | 4 | 0 |
| Socket focused (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/package-socket-focused.log`) | 3 | 3 | 0 | 0 |
| App unit (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/app-unit-full.log:6972`) | 420 | 418 | 2 | 0 |
| Thumbnail focused (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/app-thumbnail-focused-final.log`) | 8 | 8 | 0 | 0 |
| Runtime scale opt-in (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/app-runtime-scale.log`) | 1 | 1 | 0 | 0 |
| App TSan (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/app-tsan.log:7023`) | 420 | 418 | 2 | 0 |
| Full Package TSan, generation2 (`/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/package-tsan.log:2528`) | 640 | 632 | 4 | **4** |

Full Package TSan remains **FAIL**: 94 failures/assertions including one unexpected, 73 interceptor initialization errors. A filtered pass cannot replace it. It was not rerun. Package skips: crash child-only entry, 10k observer lifecycle, 100k scale,20 MiB scale. App skips: RuntimeScale (separate opt-in passes) and actual input tap. Offline Python raw log says37/OK; packaging guard8 points; full lint 449 files / 0 violations; parse log explicitly 449 / exit 0; pinned tools XcodeGen 2.45.4 / SwiftLint 0.63.2. None of these was rerun here.

Five executable hashes, actual plist values, lipo architectures and exact validator commands are in [artifact-independent-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/artifact-independent-audit.json); all are `x86_64 arm64`, not proof of Intel/macOS 14 execution.

| Release artifact under `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3` | Version | Executable SHA-256 | Independent metadata gate |
|---|---|---|---|
| `ReleaseShippingDerivedData/Build/Products/Release/MacClippy.app` | 1.0.0 (1) | `d762b00d08ea0da4a741163ba2cbc35c7fec9153fdce4d10ef1660a42cdf3022` | PASS |
| `ReleaseE2EDerivedData/Build/Products/Release/MacClippyE2E.app` | 1.0.0 (1) | `0037effa3eff297428327fdbed547eeb2c589b5c80e793a7c991b6fc7f89baf5` | PASS |
| `Swift6ReleaseDerivedData/Build/Products/Release/MacClippy.app` | 1.0.0 (1) | `9fa9fd7137383f8e65488e050ccec33b2f5647655a5f9518552755bde70b037e` | PASS |
| `ReleaseShippingOverrideDerivedData/Build/Products/Release/MacClippy.app` | 1.2.3 (42) | `7833eae4f8a6b84a6d9e653878b0630ec8292a69d1213768ee3ee8da959a2504` | PASS |
| `ReleaseE2EOverrideDerivedData/Build/Products/Release/MacClippyE2E.app` | 1.2.3 (42) | `9e413458cd4fff45185cbb9b58dc8115fb99dc6e1dc44ee7f96a986a9cdcf5bd` | PASS |

E2E embedded configuration/digest checked before launch. Shipping bundles were only read, never launched. Release log/source bindings are in [build-manifest-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/build-manifest-audit.json); no new build, remote CI, signing, notarization or publication occurred. The repository release skill `/Users/mingjie/Documents/github/personal-projects/mac-clippy/.agents/skills/macos-app-release/SKILL.md` was used as review guidance; it did not authorize any release action.

**Limitations and handoff**

Environment: macOS 26.6.2 build 25G83; Mac16,6 / Apple M4 Max / 16 logical CPUs / 64 GiB; Xcode 26.4.1 build 17E202; Apple Swift 6.3.1; Python 3.9.6. Commands/output: [environment-and-static-commands.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/environment-and-static-commands.json). No performance benchmark was conducted. Socket timings are functional deadline evidence only; no panel/search p95/p99 or competitor claims.

macOS 14, real recipient apps, permission/lifecycle UI, visible panel/preview, and 24h/72h soak are **NOT RUN/BLOCKED**. No general pasteboard, installed PID 50253, TCC, or user clipboard/data was accessed. No visible app automation or external app launch occurred. Both synthetic app roots/keys are absent; first process was terminated via its owned socket, second exited during the failing peer-close scenario; neither was externally signaled. See [independent-cleanup-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-e2e/independent-cleanup-audit.json).

Root must return the new P1 (and P2 evidence) to Luna/max, establish a new frozen generation after remediation, then repeat independent review and the unfinished capture→controlled restart→all persisted proofs→search→fresh capture/search→cleanup sequence. **Do not label this partial review or the inherited smoke as a full generation-3 PASS.**

**Complete initial changed/untracked inventory**

Each path's SHA/size and build-manifest membership is in `/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/inventory-start.json`. The following is the complete 268-path initial inventory, including project settings, migrations split into Swift sources, tests, CI/release scripts, documents, and preexisting caches. Reviewer outputs added later are separately limited to the two authorized reports and Astra evidence directories.

**tracked changed (112)**

```text
.github/workflows/ci.yml
.github/workflows/release.yml
MacClippy.xcodeproj/project.pbxproj
MacClippy/Info.plist
MacClippy/MacClippyApp.swift
MacClippy/MacClippyAppDelegate+DisplayLifecycle.swift
MacClippy/MacClippyAppDelegate+Maintenance.swift
MacClippy/MacClippyCardThumbnailLoader.swift
MacClippy/MacClippyDetails+Sections.swift
MacClippy/MacClippyDiagnosticsExporter.swift
MacClippy/MacClippyDockController+Input.swift
MacClippy/MacClippyDockController+Lifecycle.swift
MacClippy/MacClippyDockController.swift
MacClippy/MacClippyDockModel+Actions.swift
MacClippy/MacClippyDockModel+BatchActions.swift
MacClippy/MacClippyDockModel+QueueActions.swift
MacClippy/MacClippyDockModel+Utilities.swift
MacClippy/MacClippyDockPolicies.swift
MacClippy/MacClippyFileThumbnailLoader.swift
MacClippy/MacClippyRuntime+BatchActions.swift
MacClippy/MacClippyRuntime+ClipboardActions.swift
MacClippy/MacClippyRuntime+History.swift
MacClippy/MacClippyRuntime+HistoryProjection.swift
MacClippy/MacClippyRuntime+Lifecycle.swift
MacClippy/MacClippyRuntime+Maintenance.swift
MacClippy/MacClippyRuntime+MaintenanceHealth.swift
MacClippy/MacClippyRuntime+MaintenanceRepair.swift
MacClippy/MacClippyRuntime+OCR.swift
MacClippy/MacClippyRuntime+OrderedActions.swift
MacClippy/MacClippyRuntime+Preview.swift
MacClippy/MacClippyRuntime+QueueActions.swift
MacClippy/MacClippyRuntime+SearchMaintenance.swift
MacClippy/MacClippyRuntime+StorageHealth.swift
MacClippy/MacClippyRuntime.swift
MacClippy/MacClippyRuntimeModels.swift
MacClippy/MacClippySettings+Maintenance.swift
MacClippy/MacClippySettings+Sections.swift
MacClippy/MacClippySettings.swift
MacClippy/MacClippySettingsWindowCoordinator.swift
MacClippy/MacClippyUserFacingError+Typed.swift
MacClippyKit/Sources/MacClippyCore/BlobStore.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+BatchReads.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+BlobReferences.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+CaptureDedup.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+DeletionJournal.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+Retention.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackupSettingsPolicy.swift
MacClippyKit/Sources/MacClippyCore/MacClippyCaptureDedupPolicy.swift
MacClippyKit/Sources/MacClippyCore/MacClippyClipboardRepresentation.swift
MacClippyKit/Sources/MacClippyCore/MacClippyDiagnostics.swift
MacClippyKit/Sources/MacClippyCore/MacClippyReconciliation.swift
MacClippyKit/Sources/MacClippyCore/MacClippySearchRepair.swift
MacClippyKit/Sources/MacClippyCore/MacClippyThumbnailDiskCache.swift
MacClippyKit/Sources/MacClippyCore/PathsDatabase.swift
MacClippyKit/Sources/MacClippyCore/PinboardSnippetStores.swift
MacClippyKit/Sources/MacClippyCore/RetentionPolicy+Storage.swift
MacClippyKit/Sources/MacClippyCore/SearchStore.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyCardDragExportPolicy.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjectionGate.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardPreparation.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardReadRetryState.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardWriteSentinel.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpansionPlanner.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetKeyPoster.swift
MacClippyKit/Sources/MacClippyPlatform/PasteboardCapture.swift
MacClippyKit/Sources/MacClippyPlatform/PasteboardMapping.swift
MacClippyKit/Sources/MacClippyPlatform/PasteboardObserverLifecycle.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupSettingsPolicyTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyCaptureDedupPolicyTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyCaptureDedupStoreTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyCoreTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyDeletionJournalTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyInputLimitTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyRecoveryTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyRepresentationsTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyThumbnailDiskCacheTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorRestoreTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardObserverLifecycleTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardObserverRetryTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardObserverTestReader.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardWriteSentinelTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySendableBoundaryTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpanderRestoreTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpansionPlannerTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/PasteboardRepresentationsTests.swift
MacClippyTests/MacClippyCopyAllTests.swift
MacClippyTests/MacClippyCopyPrepareFailureTests.swift
MacClippyTests/MacClippyLabelTests.swift
MacClippyTests/MacClippyPasteMetadataFailureTests.swift
MacClippyTests/MacClippyQueuePasteModelTests.swift
MacClippyTests/MacClippyQueuePasteTests.swift
MacClippyTests/MacClippyRuntimeBatchOperationsTests.swift
MacClippyTests/MacClippyRuntimeBatchTests.swift
MacClippyTests/MacClippyRuntimeConcurrencyTests.swift
MacClippyTests/MacClippyRuntimeOCRConcurrencyTests.swift
MacClippyTests/MacClippyRuntimeSearchScaleTests.swift
MacClippyTests/MacClippySnippetTests.swift
MacClippyTests/MacClippyTransformTests.swift
MacClippyUITests/MacClippyUITests.swift
Makefile
README-CN.md
README.md
project.yml
scripts/archive-signed.sh
scripts/package-dmg.sh
scripts/release.sh
scripts/verify-build-metadata.sh
```

**untracked (156)**

```text
MacClippy.xcodeproj/xcshareddata/xcschemes/MacClippyE2E.xcscheme
MacClippy/E2E-Info.plist
MacClippy/MacClippyAppDelegate+BackupRestore.swift
MacClippy/MacClippyAppDelegate+HotKeys.swift
MacClippy/MacClippyAppDelegate+Lifecycle.swift
MacClippy/MacClippyAppDelegate+Presentation.swift
MacClippy/MacClippyAppDelegate+Startup.swift
MacClippy/MacClippyAsyncOperation.swift
MacClippy/MacClippyCaptureQueueAdmission.swift
MacClippy/MacClippyDockCardPolicies.swift
MacClippy/MacClippyDockController+AnimationLifecycle.swift
MacClippy/MacClippyDockController+InputPasteTarget.swift
MacClippy/MacClippyDockController+KeyRouting.swift
MacClippy/MacClippyE2EBuildIdentity.swift
MacClippy/MacClippyE2ECaptureFixture.swift
MacClippy/MacClippyE2EControlMetrics.swift
MacClippy/MacClippyE2EControlPaste.swift
MacClippy/MacClippyE2EControlRequests.swift
MacClippy/MacClippyE2EControlServer.swift
MacClippy/MacClippyE2EControlUI.swift
MacClippy/MacClippyE2EControlVerification.swift
MacClippy/MacClippyE2EFileKeychain.swift
MacClippy/MacClippyE2EIsolation+Validation.swift
MacClippy/MacClippyE2EIsolation.swift
MacClippy/MacClippyE2ERecipient.swift
MacClippy/MacClippyFileThumbnailScheduler.swift
MacClippy/MacClippyMaintenanceIOCoordinator.swift
MacClippy/MacClippyMaintenanceIOTestHooks.swift
MacClippy/MacClippyRuntime+Backup.swift
MacClippy/MacClippyRuntime+ClipboardTestSupport.swift
MacClippy/MacClippyRuntime+HistoryEditing.swift
MacClippy/MacClippyRuntime+ImageCompression.swift
MacClippy/MacClippyRuntime+ImageCompressionCommit.swift
MacClippy/MacClippyRuntime+SearchRepair.swift
MacClippy/MacClippyRuntime+StorageHealthReports.swift
MacClippy/MacClippyRuntime+StorageReconciliation.swift
MacClippy/MacClippyRuntime+StorageUsage.swift
MacClippy/MacClippyRuntime+Synchronization.swift
MacClippy/MacClippyRuntimeStorageBootstrap.swift
MacClippy/MacClippySettingsDefaultsProvider.swift
MacClippyKit/Sources/MacClippyCore/BlobLease.swift
MacClippyKit/Sources/MacClippyCore/ClipboardRecordEnvelope.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+AttachmentReferenceAuthentication.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+AttachmentReferenceQueries.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+AttachmentReferences.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+Capture.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+IndexedImageBlobIDs.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+Migrations.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+RepresentationDeletion.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+RepresentationRoster.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+RepresentationValidation.swift
MacClippyKit/Sources/MacClippyCore/ClipboardStore+Representations.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup+Create.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup+FileIO.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup+KeyValidation.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup+Restore.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup+Snapshot.swift
MacClippyKit/Sources/MacClippyCore/MacClippyBackup+Validation.swift
MacClippyKit/Sources/MacClippyCore/MacClippyMaintenanceDatabaseHealth.swift
MacClippyKit/Sources/MacClippyCore/SearchStore+Health.swift
MacClippyKit/Sources/MacClippyCore/SearchStore+MaintenanceIndex.swift
MacClippyKit/Sources/MacClippyCore/SearchStore+MaintenancePages.swift
MacClippyKit/Sources/MacClippyCore/SearchStore+RepairPages.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector+Injection.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector+Snapshot.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+DeferredInput.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+Expansion.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+Input.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+Lifecycle.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetFocusContext+AXReader.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetFocusContext+Models.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetFocusContext.swift
MacClippyKit/Sources/MacClippyPlatform/MacClippyUnixSocketLineTransport.swift
MacClippyKit/Sources/MacClippyPlatform/PasteboardCapture+Reading.swift
MacClippyKit/Sources/MacClippyPlatform/PasteboardObserverLifecycle+Controls.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyAttachmentReferenceIndexTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyAttachmentRetentionSafetyTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyAuthenticatedRepresentationRosterTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupCompatibilityTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupHistoricalSchemaFixtures.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupHistoricalSchemaTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashChildProtocol.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashFixtures.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashIsolation.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashLauncher.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashStorageVerifier.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashSupport.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupProcessCrashWorker.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupRestoreTransactionTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupValidationTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBlobLeaseTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyBoundedHealthTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyCaptureDedupIntegrityTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyRepresentationCaptureRollbackTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyRepresentationPayloadTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippyRepresentationStateTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippySearchMaintenanceIndexTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippySearchRepairPageTests.swift
MacClippyKit/Tests/MacClippyCoreTests/MacClippySearchStoreBehaviorTests.swift
MacClippyKit/Tests/MacClippyCoreTests/RestoreCrashExecutionVerifier.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorGateTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorGenerationOwnershipTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorTargetTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardObserverRecoveryTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardObserverRestartTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetDeferredInputLifetimeTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpanderContextCancellationTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpanderTestSupport.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetInputCommitTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySystemPasteboardReaderTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippySystemPasteboardRetryTests.swift
MacClippyKit/Tests/MacClippyPlatformTests/MacClippyUnixSocketLineTransportTests.swift
MacClippyTests/MacClippyCardThumbnailStaleWaiterTests.swift
MacClippyTests/MacClippyE2EBuildIdentityTests.swift
MacClippyTests/MacClippyFileThumbnailSchedulingTests.swift
MacClippyTests/MacClippyMaintenanceIOTests.swift
MacClippyTests/MacClippyPasteResultModelTests.swift
MacClippyTests/MacClippyPasteResultRuntimeTests.swift
MacClippyTests/MacClippyPasteResultTestSupport.swift
MacClippyTests/MacClippyQueuePasteCancellationIntegrationTests.swift
MacClippyTests/MacClippyQueuePasteLifecycleTests.swift
MacClippyTests/MacClippyRuntimeBatchRepresentations.swift
MacClippyTests/MacClippyRuntimeCaptureBackpressureTests.swift
MacClippyTests/MacClippyRuntimeRetentionPolicyTests.swift
MacClippyTests/MacClippyRuntimeSearchRepairTests.swift
MacClippyTests/MacClippySearchRepairTestSupport.swift
docs/competitive-comparison.md
docs/e2e-phase5.md
docs/hardening-progress.md
docs/release-process.md
docs/restore-process-tests.md
docs/review/astra-e2e-results-generation2.md
docs/review/astra-e2e-results.md
docs/review/astra-package-rereview.md
docs/review/astra-package-rereview2.md
docs/review/astra-source-review-generation2.md
docs/review/astra-source-review.md
scripts/assert-opt-in-xctest-log-test.sh
scripts/assert-opt-in-xctest-log.sh
scripts/e2e/__pycache__/macclippy-phase5.cpython-314.pyc
scripts/e2e/__pycache__/test_macclippy_phase5.cpython-314.pyc
scripts/e2e/macclippy-e2e-launch.swift
scripts/e2e/macclippy-e2e-rusage.c
scripts/e2e/macclippy-phase5.py
scripts/e2e/test_macclippy_phase5.py
scripts/package-dmg-path-guard-test.sh
scripts/release-script-test.sh
scripts/retarget-nightly-tag-test.sh
scripts/retarget-nightly-tag.sh
scripts/select-release-version-test.sh
scripts/select-release-version.sh
scripts/verify-build-metadata-test.sh
scripts/verify-make-pinned-tools-test.sh
scripts/verify-required-ci-test.sh
scripts/verify-required-ci.sh
```

Final read-only preservation check: [/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/preservation-and-output-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-3/astra-review/preservation-and-output-audit.json). All 268 preexisting inventory paths retain their initial bytes; only the two authorized reports were added to the git-visible inventory. The final source/control digest remains unchanged.

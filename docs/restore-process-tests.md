# Restore process crash tests

`MacClippyBackupProcessCrashTests` runs the restore worker through `xctest` in a separate process. The launcher resolves the loaded XCTest bundle with `Bundle(for: MacClippyBackupProcessCrashTests.self)`, requires an existing executable inside the `.xctest` bundle, selects only `testChildWorkerEntryPoint`, and records bounded stdout and stderr for each child under its marked temporary fixture.

The worker requires a private child mode, a per-launch nonce, a matching request in its current marked fixture directory, and the fixture token. The ordinary test suite skips the worker entry point without that explicit binding; it does not scan temporary directories.

Each old and restored generation has real clipboard and search databases plus pinboard and snippet databases. Fixtures use production store APIs to persist two distinct authenticated clipboard bodies, an image attachment and a blob-backed image representation, searchable documents, a pinboard referencing the text record, and an encrypted snippet. The disposable 256-bit key is stored only in the marked fixture so each process can reopen the same data. Database queues are closed before an install child starts.

After every simulated process death, a new XCTest child runs recovery to completion. The parent then runs recovery twice more and opens all four databases and both blob payloads with the persisted fixture key. Assertions compare exact clipboard IDs and bodies, attachment and representation IDs and bytes, search result IDs, pinboard IDs and record membership, snippet IDs and contents, encrypted component markers, and the live component set. A mixture of old and restored fixture data fails those exact-generation checks.

## Boundaries exercised

- Install hooks: before and after each live component, plus before commit.
- Recovery hooks: after rollback of each live component, after rollback commit, before and after transaction cleanup, and before journal cleanup.
- Finalization hook: after the restore is finalized.
- Staged move micro-boundary: a test-only `FileManager` override sees the destination already removed and the staged source still present, then either sends `SIGKILL` to the isolated worker or throws injected `EIO`. Both actions are restricted to one whitelisted live component below the marked fixture root.

These tests exercise process termination and injected filesystem errors at named code boundaries. They do not claim power-loss, storage-controller, or `fsync` durability coverage.

## Verified run

On 2026-09-25, the focused test class passed with 6 tests executed, 1 intentional skip, and 0 failures. The skip is the child-only worker entry point when the ordinary suite does not have its private mode, nonce, and marked fixture request. The class validated 18 `SIGKILL` cases and 3 injected `EIO` cases:

| Operation | Child deaths | Checkpoints |
| --- | ---: | --- |
| Install | 7 | `beforeInstall` and `afterInstall` for `databases`, `blobs`, and `thumbnails`; `beforeCommit` |
| Staged move | 3 | After destination removal and before staged move for `databases`, `blobs`, and `thumbnails` |
| Rollback and cleanup | 7 | `afterRollback` for each component; `afterRollbackCommit`; `beforeTransactionCleanup`; `afterTransactionCleanup`; `beforeJournalCleanup` |
| Finalize | 1 | `afterFinalize` |

Each death was followed by a successful recovery child, two idempotent parent recovery calls, and a fresh open and exact-generation assertion across the complete storage set. The staged-move I/O test injected `EIO` once per live component and confirmed the install call surfaced the error and restored the old generation.

The launcher selected `MacClippyBackupProcessCrashTests/testChildWorkerEntryPoint` from the loaded `MacClippyKitPackageTests.xctest` bundle and verified its executable. Each launch wrote nonce-matched start and boundary evidence and retained stdout/stderr capped at 32 KiB per stream under the marked fixture.

The focused test run used a read-only source snapshot with a separate SwiftPM scratch directory. Its focused-test log is `/tmp/macclippy-phase5-restore-process-handoff-test.log`.

## Focused commands

Run the package test target from a read-only source snapshot, with SwiftPM scratch output outside the snapshot:

```sh
swift test \
  --package-path /tmp/macclippy-phase5-restore-process-handoff-snapshot/MacClippyKit \
  --scratch-path /tmp/macclippy-phase5-restore-process-handoff-build \
  --disable-automatic-resolution \
  --filter MacClippyCoreTests.MacClippyBackupProcessCrashTests
```

The owned Swift files are linted with SwiftLint 0.63.2 in strict mode. The crash test suite is intentionally bounded to its small synthetic records and does not run application, Xcode, or GUI tests.

# MacClippy 生产就绪 Goal — 当前执行计划

## 目标

在不扩大到父工程的前提下，把 `mac-clippy/` 推进到可验证的公开分发门槛。优先处理数据恢复、输入边界、权限/签名和可观测性；不把 ad-hoc Debug 产物当成发布证据。

## 当前阶段

- [completed] Phase 0：记录基线、工具链和环境限制
- [completed] P0-A：Hardened Runtime、archive/sign/verify/notarization 与 CI 骨架（真实 Developer ID/notarization 仍受环境阻塞）
- [completed] P0-B：数据库健康、备份恢复、FTS repair、blob/deletion integrity
- [completed] P0-C：pasteboard 输入上限和保守安全默认值
- [completed] P0-D：脱敏日志、diagnostics、degraded/recovery UX
- [completed] P1：并发、paste 权限状态机、隐私默认值与关键性能修复（代码与自动测试完成）
- [completed] 发布验证的本地可执行部分：代码侧、规模夹具、生命周期压力、Debug bundle metadata 已验证
- [blocked] 外部发布验证：真实 integration/soak、Developer ID 签名、公证与 Gatekeeper 需要外部环境/凭据

## 2026-08-03 P1-A 生命周期补强

- Added a dedicated runtime lifecycle lock to close the start/stop resource
  installation race and a repeated transition regression test.
- App test-bundle compilation, package tests, TSan, and metadata verification
  passed after the change.
- The new App test is not marked executed because the same LaunchServices
  worker-materialization blocker remains.

## 2026-08-03 最终代码侧验收

- Diagnostics latency instrumentation warning fixed with a one-line removal of
  an unnecessary `try` in the queued-paste path.
- Package suite and Thread Sanitizer both pass 213/213.
- Xcode project generation, unsigned Debug arm64 App build, App test-bundle
  compilation, and bundle metadata verification pass.
- The blocked release-validation phase is unchanged: no Developer ID identity,
  notarization/Gatekeeper evidence, clean-user TCC matrix, real pasteboard or
  CGEvent integration, Instruments profile, or long-running soak evidence is
  available in this environment.

## 约束

- 只修改 `mac-clippy/`，保留已有 dirty changes。
- 不写入证书、密码、API token 或 notarization 凭据。
- 不绕过环境 Guard；真实 archive/sign/notarize/Gatekeeper 证据需要显式 deploy authorization 和 Developer ID 证书。
- 所有剪贴板正文、图片、OCR、文件路径和敏感错误上下文必须脱敏。
- 每项修复先有可复现测试或最小静态证据，再做实现。

## 2026-08-03 scale/lifecycle verification

- `MACCLIPPY_RUN_STRESS_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyLifecycleStressTests`: 1/1 passed; 10,000 observer start/poll/stop cycles completed in 0.172s.
- `MACCLIPPY_RUN_SCALE_TESTS=1 swift test --package-path MacClippyKit --filter MacClippyScaleTests`: 2/2 passed; 100,000-record search/pagination and 20 MiB representation spill/delete completed in 27.560s.
- No fixture clipboard body, OCR text, or image payload was emitted by the scale tests.

## 验收证据

- `swift test --package-path MacClippyKit` 全部通过。
- Debug/Release arm64 编译通过；签名、公证和 Gatekeeper 只有在证书/授权具备时记录真实成功结果。
- 健康检查、备份/恢复、FTS repair、pasteboard limits 和 diagnostics 有自动化测试。
- `progress.md` 记录实际命令、版本、测试数量、失败原因和残余风险。

## 错误与阻塞

| 错误/阻塞 | 尝试 | 处理 |
| --- | --- | --- |
| 组合只读命令被环境 Guard 判定为发布动作 | 1 | 不绕过；拆分只读审计。真实发布动作保留为后续授权门槛。 |
| 当前 `project.yml` Debug 禁止代码签名，entitlements 为空 | 1 | 作为 P0-A 配置缺口；加入显式 Hardened Runtime/签名流程骨架，等待证书验证。 |
| Release arm64 build | 1 | 被本地 deploy/release Guard 在执行前阻止；未绕过，保留为 Developer ID 发布门槛。 |
| Runtime teardown cleanup | 1 | 初次加入数据库关闭时与既有 `deinit` 重复声明；已合并为单一 `deinit` 并通过编译/测试。 |
| Deletion journal omitted text-only record IDs | 1 | Blob-only journal had no row for records without external blobs; added `clipboard_deletion_records` migration/table and replay coverage. |
| `blobIDs(for:)` swallowed reference lookup failures | 1 | Propagate lookup errors before deletion journaling; non-image records use persisted `content_kind` and avoid unnecessary envelope decryption. |
| QueuePaste XCTest teardown still held a secondary Runtime | 1 | Closed the Runtime retained by the Dock model before deleting the shared temporary root; full App XCTest no longer emits SQLite WAL/SHM unlink warnings. |
| Test cleanup edit matched a used `first/second/third` declaration | 1 | Restored the visual-order test declarations and applied warning cleanup to the intended manual-stop test; reran focused and full suites. |
| Xcode App target used a stale MacClippyCore module interface after SearchStore API addition | 1 | Package tests saw the new API, but the existing DerivedData App compile reported missing methods; retry with a fresh DerivedData path before classifying the target as passing. |
| Xcode App test runner did not materialize a worker after the FTS/startup test additions | 1 | Historical targeted run was interrupted after about 90 seconds with `waiting for workers to materialize`; a later fresh full run completed 123/123, so this is retained as historical environment noise rather than a current test blocker. |
| Combined read-only audit command was blocked by the local deploy/release Guard | 1 | Split the command into independent read-only checks; no Guard bypass was attempted. |
| Final shell syntax recheck for publishing scripts was blocked by the local deploy/release Guard | 1 | Reused the earlier recorded `bash -n` evidence; no publishing command or Guard bypass was attempted. |
| Direct `xctest` runner was unavailable | 1 | Confirmed the command is not installed; retained the Xcode worker-materialization issue as the App XCTest environment blocker and did not claim execution. |
| Targeted SwiftLint run exited 2 on existing large-file/type, complexity, identifier, and line-length violations | 1 | Recorded as deferred structural debt; behavior changes were not mixed with a broad refactor. |

## 决策记录

- 继续 Swift/AppKit/SwiftUI，不迁移 Tauri。
- P0-A 先做可审计、无凭据的脚本和 build settings；不伪造 Developer ID/notarization 结果。
- 生产默认过滤策略需要回到保守模式；“Capture All” 必须是显式 opt-in，而不是隐式默认。
- `PasteboardObserver` 的 timer、handler、generation、retry、pause 和 exclusion 配置现在由同一 lifecycle serial queue 协调；配置更新异步排队，不让主线程等待 provider read。
- Observer concurrency evidence: focused retry-state tests passed 7/7 and observer retry tests 10/10; Thread Sanitizer package run passed 196/196 with no race report.
- Observer startup health evidence: after reconciliation, the runtime records a fixed, redacted health event for each non-healthy database; the FTS marker path is covered by an App regression test that compiled successfully, but its runner is blocked by the current XCTest worker-materialization issue.
- Final package verification after this continuation: `swift test --package-path MacClippyKit` passed 200/200; `xcodegen generate` passed; Debug arm64 app build and App test bundle compilation passed.
- CI now includes a shipping-configuration compile plus Hardened Runtime and bundle metadata checks. This is compile/metadata evidence only, not Developer ID signing or notarization evidence.
- Scoped SwiftLint still exits 2 on pre-existing large-type/file, complexity, line-length, identifier, and other maintenance violations; no broad decomposition was mixed into the behavior fixes.
- Reconciliation cleanup now returns failed orphan Blob/FTS IDs instead of swallowing them, and Runtime exposes those failures through degraded storage reasons and redacted diagnostics.
- Retention total-size enforcement now propagates unreadable-record errors instead of silently skipping corrupted records.

## 2026-08-03 隐私 UX 与最终验证

- 增加隐私与数据说明页面，并从 Settings 暴露入口；说明本地存储、删除范围、当前 build 的网络边界，以及 diagnostics/backup 的边界。
- 增加设置层回归测试，确保删除范围和网络边界文案不会被意外移除。
- `swift test --package-path MacClippyKit`：204/204 通过。
- `xcodegen generate`：通过。
- unsigned Debug arm64 App build：通过，产物位于 `build/verify-final-app/Build/Products/Debug/MacClippy.app`。
- `scripts/verify-build-metadata.sh build/verify-final-app/Build/Products/Debug/MacClippy.app`：通过。
- 最新 App XCTest 已成功完成编译，但两个 clean DerivedData test runs 都在启动 XCTest worker 前停在 `waiting for workers to materialize`；均未计为业务断言失败，也未伪造测试通过证据。此前同一 scheme 的完整 App XCTest 已有 123/123 通过记录。

## 2026-08-03 Paste restore 与规模验证 follow-up

- Paste injector 现在对不可完整 snapshot 的 lazy provider 原 clipboard 采取 fail-safe manual paste，不再执行可能丢失原 item 的清空/恢复流程。
- 已完成 100,000 条历史 + FTS 搜索分页、20 MiB representation spill/delete 的 opt-in scale 验证；结果记录在 `findings.md` 和 `progress.md`。
- Release configuration compile 仍需 deploy authorization；当前不能把 Debug unsigned build 代替 Release、签名或 Gatekeeper 证据。

## 2026-08-03 Lifecycle pressure follow-up

- 新增 observer 10,000-cycle lifecycle stress fixture，并加入 CI 独立 step；本机 1/1 通过。
- App XCTest 的 no-parallel fallback 仍复现同一 LaunchServices worker materialization blocker，继续保留为环境证据，不把它标记为业务失败或通过。

- 本轮普通 Package suite：208/208 通过；changed-file SwiftLint 通过。

## 2026-08-03 Signed artifact verifier follow-up

- 加强签名验证脚本，避免没有 hardened runtime 的 Developer ID 包被误判为可发布。
- 本地仅完成 shell syntax verification；真实签名链仍需要 Developer ID identity、notary profile 和 Gatekeeper 环境。

## 2026-08-03 收尾验收

- Re-ran `xcodegen generate`: passed.
- Re-ran unsigned Debug arm64 app build with `CODE_SIGNING_ALLOWED=NO`: passed.
- Latest package suite: 200/200 passed. The latest targeted App test bundle compiled with `build-for-testing`; the test runner did not materialize a worker and was interrupted with exit 75.
- Scoped SwiftLint remains non-zero because of pre-existing structural debt; no new broad refactor was introduced.
- Release remains gated on Developer ID signing, notarization/stapling/Gatekeeper, real TCC/Keychain/NSPasteboard/CGEvent integration, and Instruments-scale soak evidence.

## 2026-08-03 P0-B cleanup failure propagation follow-up

- Added `failedBlobCleanupIDs` and `failedFTSCleanupIDs` to
  `MacClippyReconciliation.Result`; individual orphan cleanup failures no
  longer disappear while allowing the remaining sweep to continue.
- Runtime now marks orphan cleanup/reconciliation failures as degraded,
  records `reconciliationFailed`, and only records `reconciliationCompleted`
  when all detected orphan cleanup operations succeeded.
- `RetentionPolicy.enforceTotalCap` now fails closed on an unreadable record;
  it cannot enforce a size cap by pretending corrupted storage has zero cost.
- Focused tests: Reconciliation 7/7 and Input/Retention 4/4.
- Full package suite: `swift test --package-path MacClippyKit` passed 204/204.
- Debug arm64 app build passed in `build/verify-integrity`; App
  `build-for-testing` passed in `build/verify-integrity-tests`.
- `scripts/verify-build-metadata.sh` passed for the rebuilt App.
- Full scheme-qualified App XCTest passed 123/123, 0 failed, 0 skipped in
  `/tmp/macclippy-followup-20260803.xcresult`.

## 2026-08-03 implementation continuation

- [x] Re-audit production `try?` sites for data-loss, false-success, and
  recovery semantics.
- [x] Preserve successful paste results when only the post-paste frequency
  metadata write fails; add a redacted diagnostic event and regression test.
- [x] Regenerate the Xcode project and compile the App XCTest target with
  `build-for-testing`.
- [x] Re-run the MacClippyKit package suite.
- [x] Surface global-hotkey rollback failure instead of claiming the previous
  shortcut was restored.
- [ ] Execute the new App XCTest in this environment; the focused runner is
  blocked after build by the local LaunchServices/XCTest worker startup hang.
- [ ] Complete Release signing, notarization, Gatekeeper, TCC, real-system
  integration, soak, and Instruments evidence; these remain external release
  gates rather than code claims.

### Errors encountered in this continuation

| Error | Attempt | Resolution |
|---|---:|---|
| New app test initially missed `MacClippyPlatform` import | 1 | Added the package import; `build-for-testing` then succeeded. |
| Focused XCTest stalled before worker/test execution | 1 | Stopped the spawned runner after no progress; retained compile evidence and did not claim execution. |
| zsh `status` is read-only in a verification wrapper | 1 | Read the build log directly; it contains `** TEST BUILD SUCCEEDED **`. |

## 2026-08-03 latency metrics follow-up

- [x] Add a bounded, lock-protected diagnostics latency aggregator with count,
  total, max, and average duration fields.
- [x] Record runtime latency for capture, history search, ordinary/Snippet/
  transform/ordered/queued paste, and storage reconciliation.
- [x] Include aggregated metrics in diagnostics export without including
  clipboard body, image bytes, OCR text, or file paths.
- [x] Add focused aggregation, input-boundary, clear, capacity, and concurrent
  recorder tests.
- `swift test --package-path MacClippyKit`: 213/213 passed.
- `swift test --package-path MacClippyKit --sanitize=thread`: 213/213 passed;
  no ThreadSanitizer race report.
- `xcodegen generate`: passed.
- Debug arm64 App/test `build-for-testing`: passed in
  `build/build-for-testing-latency-final`.
- `scripts/verify-build-metadata.sh
  build/build-for-testing-latency-final/Build/Products/Debug/MacClippy.app`:
  passed.

### Remaining boundary after this follow-up

The metrics are instrumentation and regression evidence, not a substitute for
Instruments CPU/memory/energy sampling. Developer ID signing, notarization,
Gatekeeper, clean-user TCC/Keychain/Accessibility/Input Monitoring,
real NSPasteboard/provider and CGEvent integration, and 24–72 hour soak remain
external release gates. The App XCTest LaunchServices worker-materialization
blocker remains unchanged; this follow-up only claims successful test-bundle
compilation.

## 2026-08-03 privacy notice interaction fix

- [completed] Defer the first privacy alert until the next main-run-loop turn
  so the menu-bar agent does not enter `runModal()` during
  `applicationDidFinishLaunching`.
- [completed] Route `Open Settings` through SwiftUI's standard
  `showSettingsWindow:` action, then bring the asynchronously-created window
  forward.
- [completed] Rebuild the App/test bundle and rerun the package suite.
- [blocked] Live click verification on this machine is currently blocked by
  the debug app hanging in Keychain `SecItemCopyMatching` before reaching the
  privacy alert.

## 2026-08-04 Final cleanup review

- [completed] Inventory current source, build configuration, generated artifacts, and release/privacy risks.
- [completed] Run package/app baseline tests and static quality checks.
- [completed] Remove only verified unused/stale source or generated artifacts; make minimal high-confidence fixes.
- [completed] Re-run tests, builds, metadata checks, and record remaining release blockers.

### Scope for this phase

- Target only `/Users/mingjie.wang/Documents/personal/mac-all-you-need/mac-clippy`.
- Preserve unrelated dirty files and historical planning/review documents.
- Do not use `git clean`, `git reset`, or broad recursive deletion.
- A deletion requires a reference check, project-file check, and generated-artifact check.

### Final verification

- `make test`: package suite 213/213 and App XCTest 137/137 passed, 0 failures.
- `./scripts/verify-build-metadata.sh .build/DerivedData/Build/Products/Debug/MacClippy.app`: passed.
- `swiftlint lint --quiet MacClippy MacClippyKit/Sources`: remains non-zero only for documented structural/style debt; no unused-import or unused-declaration finding was reported.
- The final Debug build is valid for local verification only; it is not a signed/notarized release artifact.

### Final phase status

- [completed] Source/artifact cleanup and regression verification.
- [blocked] Public privacy policy URL, Developer ID/notarization/Gatekeeper, clean-user permission matrix, real system integration, and Instruments/soak evidence remain external release gates.

## 2026-08-04 DMG packaging target

- [completed] Mirror the parent project's DMG packaging flow in `mac-clippy`.
- [completed] Add `make dmg` and `make release` targets.
- [pending] Verify shell syntax and create a local unsigned DMG.

### Final cleanup decisions

- Remove only the two unreferenced private helpers and generated Finder/build artifacts.
- Retain historical `PLAN-*.md`, readiness reports, README, tests, and public compatibility aliases.
- Treat SwiftLint's large-file/complexity failures as structural debt; do not hide them with a broad refactor in this cleanup pass.

### Errors encountered in this phase

| Error | Attempt | Resolution |
|---|---:|---|
| Initial private-function scan passed a space-separated path list as one `rg` path | 1 | Re-ran with explicit path arguments; the corrected scan found only the two safe private-helper removals. |
| First cleanup patch used an incorrect `.gitignore` context | 1 | Re-read the file and applied the same surgical patch with the exact `*.xcresult` entry. |
| One orchestration call used a non-existent `tools.exec` helper | 1 | No filesystem action occurred; continued with the supported `exec_command` tool. |

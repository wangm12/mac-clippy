# MacClippy Generation 5 Luna 修复交接

## 状态

Generation 4 的三项审查 finding 已按指定范围修改，并完成对应回归、相关本地 gates 和新建的 universal Release/E2E 往返验证。Generation 5 等待 gpt-6-astra/max 独立源码复审及详细复测；这份 handoff 不代表发布验收通过。Generation 4 的 Astra 报告及证据没有改动。

- 基线：`79e987a982f15f9193392c9af98b66465efd5ee2`
- 分支：`codex/core-reliability-hardening`
- 当前 Generation 5 source content SHA-256：`675d88ba80b67cb1c39465965cbc7f5ad1dfafa8ebb4d0affc7028af8af5cbe3`
- Source manifest：523 个 canonical inputs，见 `build/hardening-phase6-20260925/generation-5/source-manifest.json`
- Manifest 二次生成后 entries 与 source hash 全部相同；E2E Release App 的 plist 与运行中 `ping` 返回的 digest 均等于上面的 hash。

## Finding 修复

### ASR-G4-P2-001：010/011 历史 v1 roster 的维护认证

根因是 maintenance 路径打开并认证 roster 后，仍用默认 v2 规则重建 SQL roster。迁移 012 为旧 representation 行填入 `item_index = 0`，而合法 v1 roster 的规范化规则不同，普通 playback 的版本感知读取可以通过，维护认证却将合法历史数据判为 `invalidStoredRecord`。

`authenticateRepresentationRoster` 现在先通过 AES-GCM 打开 roster，再按其中已认证的 `version` 重建当前 SQL roster 并比较。v1 的兼容只接受原有 item-zero 语义；错误密钥、AEAD 篡改和与加密 representation 不匹配的数据仍被拒绝。

新增真实历史 schema 010 与 schema 011 SQLite fixture：从真实 migration 前缀建库并写入 v1 加密 body、representation payload 和 roster，再通过生产 migration 列表升级到 012。真实生产路径回归覆盖 playback、retention 删除、marker 失效后的 reconciliation/authentication，以及错误密钥、roster 篡改和有效 roster/错误 payload 不匹配。focused 结果为 3 tests / 0 failures，日志：`build/hardening-phase6-20260925/generation-5/focused/legacy-roster-tests-schema010-011.log`。

### ASR-G4-P2-002：共享 image blob 的唯一空间计费

根因是 retention 原先逐 image record 累加 primary blob 大小，并按每条被删记录抵扣，因此共享附件会重复计费，也可能误把仍有 owner 的字节当作已释放空间。

image-cap 初始用量现在从已认证的 image attachment index 按唯一 primary/representation blob ID 分页核算；候选计划以排除整批待删 owner 后得到的可回收 ID 估计释放量，提交时重新认证并核验每条候选记录的 modification time、blob IDs 和实际字节数。`deleteRecords` 在 commit fence 内复查 owner、删除孤儿 blob，并返回该提交中确实可回收的 blob IDs；image-cap 只按这组 IDs 抵扣。分页、取消、保护 owner 与 commit fence 保持在生产 retention 路径中。

`MacClippyImageCapSharedBlobTests` 的 7 tests / 0 failures 覆盖：精确唯一文件大小配额不删除；小于上限时仅按真实释放字节推进；protected owner；跨记录共享 representation；257 owners 跨删除页；提交 fence 中并发新增 owner；提交时候选 footprint 改变。日志：`build/hardening-phase6-20260925/generation-5/focused/image-cap-tests-commit-fence-revalidation.log`。额外 storage 回归 22 / 0，日志：`build/hardening-phase6-20260925/generation-5/focused/related-storage-tests-commit-fence-revalidation.log`。

### ASR-G4-P3-001：SwiftLint clean-checkout strict gate

根因是仓库 lint 仅以非 strict baseline 扫全仓；changed-file strict 条件又只查 unstaged 与 untracked，clean CI checkout 和 staged-only 修改会绕过新增 warning 检查。

`scripts/lint.sh` 现在将 staged、unstaged、untracked Swift 文件一并纳入 changed-file strict 检查，并始终对全仓执行 `--strict --baseline`。既有 baseline debt 可通过，clean checkout 新 warning 必须失败。CI 运行新增 fixture suite。

固定仓库 SwiftLint 0.63.2；fixture 5 / 5 通过，覆盖 clean checkout 新 warning 失败、已有 baseline debt 可通过，以及 unstaged、untracked、staged warning 均失败。真实仓库 strict lint 对 453 个 Swift 文件发现 0 violations；changed-file gate 检查 230 个 Swift 文件。证据：`build/hardening-phase6-20260925/generation-5/focused/lint-gate-fixtures-commit-fence.log`、`build/hardening-phase6-20260925/generation-5/gates/strict-lint-commit-fence.log`。

## Generation 5 gates

| Gate | 结果 | 原始证据 |
|---|---:|---|
| 完整 Package | 658 executed，4 skipped，0 failures | `build/hardening-phase6-20260925/generation-5/gates/full-package-commit-fence.log` |
| 完整 App | 420 executed，2 skipped，0 failures | `build/hardening-phase6-20260925/generation-5/gates/full-app-commit-fence.log` 与 `.xcresult` |
| App TSan | 420 executed，2 skipped，0 failures | `build/hardening-phase6-20260925/generation-5/gates/app-tsan-commit-fence.log` 与 `.xcresult` |
| 相关 Package TSan | 10 executed，0 failures | `build/hardening-phase6-20260925/generation-5/gates/filtered-package-tsan-commit-fence.log` |
| 完整 strict lint | 453 files，0 violations | `build/hardening-phase6-20260925/generation-5/gates/strict-lint-commit-fence.log` |
| lint fixture suite | 5 passed，0 failed | `build/hardening-phase6-20260925/generation-5/focused/lint-gate-fixtures-commit-fence.log` |
| `git diff --check` | exit 0 | 最终复核记录在 `build/hardening-phase6-20260925/generation-5/gate-status.json` |

本轮通过的主要命令：

```sh
swift test --package-path MacClippyKit --filter MacClippyLegacyRosterMaintenanceTests
swift test --package-path MacClippyKit --filter MacClippyImageCapSharedBlobTests
swift test --package-path MacClippyKit --filter 'MacClippy(CoreRetentionTests|AttachmentRetentionSafetyTests|ReconciliationTests|AttachmentReferenceIndexTests)'
swift test --package-path MacClippyKit
xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/hardening-phase6-20260925/generation-5/AppDerivedData -resultBundlePath build/hardening-phase6-20260925/generation-5/gates/full-app-commit-fence.xcresult -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 -only-testing:MacClippyTests -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/hardening-phase6-20260925/generation-5/AppTSanDerivedData -resultBundlePath build/hardening-phase6-20260925/generation-5/gates/app-tsan-commit-fence.xcresult -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 -only-testing:MacClippyTests -enableThreadSanitizer YES -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
swift test --package-path MacClippyKit --sanitize=thread --filter 'MacClippy(LegacyRosterMaintenanceTests|ImageCapSharedBlobTests)'
SWIFTLINT_BIN=/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/macclippy-tools/bin/swiftlint ./scripts/lint.sh
SWIFTLINT_BIN=/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/macclippy-tools/bin/swiftlint python3 -B scripts/lint-gate-fixture-test.py
git diff --check
```

完整 Package TSan 命令没有重跑；见下方 Generation 2 历史 FAIL 分类。

完整 Package TSan 本轮没有运行。Generation 2 已记录结果仍为 **FAIL / sanitizer child-process host limitation**：640 tests = 632 passed + 4 skipped + 4 failed，94 failure assertions（含 1 unexpected），73 条 sanitizer interceptor 初始化错误，集中在四个 crash-child 测试。filtered Package TSan 和 App TSan 的通过不覆盖这项失败。见 `docs/review/astra-source-review-generation2.md` 与 `docs/review/astra-e2e-results-generation4.md`。

## Release 和合成 E2E

以新的 DerivedData 目录分别 fresh build Shipping 与 E2E Release，均为 `x86_64` + `arm64`。Shipping bundle ID `com.macallyouneed.macclippy`，版本 `1.0.0 (1)`，可执行文件 SHA-256 `45e3e40ddcae7f11c8381c091d47887182dd613941002431a3297990d3e43dd3`。Shipping App 未启动。

E2E bundle ID `com.macallyouneed.macclippy.e2e`，版本 `1.0.0 (1)`，可执行文件 SHA-256 `c28a9ef59c28a84f449ea2d51a686ba911ca1d098ff13205c322d0325b587b34`，架构 `x86_64` + `arm64`，embedded/runtime source SHA 为 `675d88ba80b67cb1c39465965cbc7f5ad1dfafa8ebb4d0affc7028af8af5cbe3`。

E2E runner 在独立 marked temporary root 使用合成 named-board 输入并以隐藏模式启动 E2E target：两个 `public.html` items（相同 UTI）成功入库，搜索命中，生产 `verify-record` 解密读回的原始 SHA 与 capture 一致。随后 65,536-byte spilled text 在同 root、不同 PID 重启后通过加密读取，重启前后 SHA 相同。E2E 进程均退出，runner 校验并清理临时 root。摘要：`build/hardening-phase6-20260925/generation-5/release/e2e-roundtrip-summary-commit-fence.json`；逐项原始 JSON 位于同目录 `e2e-*-commit-fence.json`。

两个 Release 构建使用 `xcodebuild build`，Shipping scheme 为 `MacClippy`，E2E scheme 为 `MacClippyE2E`，均使用 `-configuration Release -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO`。E2E 构建同时传入 `MACCLIPPY_E2E_SOURCE_CONTENT_SHA256=675d88ba80b67cb1c39465965cbc7f5ad1dfafa8ebb4d0affc7028af8af5cbe3`。完整参数与原始 build log 保存在 `build/hardening-phase6-20260925/generation-5/release/{shipping-build-commit-fence,e2e-build-commit-fence}.log`。

## 尚未运行与 Astra 下一轮

下列事项保持 **NOT RUN**：macOS 14 实机；GUI/真实接收应用互操作；权限 UI；App/UI 可见 100k mixed-history；24h/72h soak；x86_64 运行时验证。Generation 5 尚无 Astra 复审结论。

Astra 请以 source SHA `675d88ba80b67cb1c39465965cbc7f5ad1dfafa8ebb4d0affc7028af8af5cbe3` 为对象独立复审，重点核对以上三个 finding 的实现和生产 API 回归，并验证 Release E2E embedded/runtime digest、Release App 身份与 raw JSON。源代码和机器可读 gate 状态见 `build/hardening-phase6-20260925/generation-5/source-manifest.json` 与 `build/hardening-phase6-20260925/generation-5/gate-status.json`。

本阶段未创建 commit、push、tag、PR，未 publish 或 release。

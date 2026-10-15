# Astra Phase 6 独立源码审查（v1.0，generation 1 中间交接）

**结论：NOT READY。已确认 P0：0；尚未独立验证修复的 P1：4、P2：6。** 本报告完成的是本轮可进行的只读审查，不是最终验收。十项发现已通过普通 commentary 即时或分批交给 root，均列于 control revision 17；P1 没有等待报告完成才上报。Luna 正在修复，所有问题保持开放，增量 red/green 日志不替代下一冻结代次的独立复审和回归。

本 worker 没有构建、运行测试、驱动 UI、启动 soak 或改动实现；仅写本报告和 `/tmp/astra-source-review-*`。没有 commit/push/tag/publish，没有接触 installed app 的生命周期、真实剪贴板、历史、Keychain 或 preferences。按 control 的 `source_review_instruction` 结束本轮，后续由 root 重新派发最终 source review / synthesis。

## 身份、环境与证据范围

| 项目 | 核实结果 |
| --- | --- |
| workspace / branch | `/Users/mingjie/Documents/github/personal-projects/mac-clippy` / `codex/core-reliability-hardening` |
| base commit | `79e987a982f15f9193392c9af98b66465efd5ee2` |
| generation 1 摘要 | `24cdd86ab8febb30814a72670f85ab3534fe41fca2c311a4a8e604edec1e0b18` |
| 冻结 manifest | `/tmp/macclippy-phase6-source-initial.json`；初始独立核对 506 个条目的 SHA-256，全数一致；这不是“506 个文件全部逐行审完”的声明 |
| 派发 Release app | `/tmp/macclippy-phase5-e2e-release-structural-final/Build/Products/Release/MacClippyE2E.app`；本 worker 未启动 |
| 派发 executable SHA-256 | `948efb789b582e8c0a8c8cd4f46075538c58d22de7792f8a852f17e13f2b1ea8`，来自 control / executor 身份记录；不冒称本 worker 的执行产物 |
| 本 worker 只读环境核实 | macOS 26.6.2 / 25G83；Xcode 26.4.1 / 17E202；Mac16,6；arm64；68,719,476,736 bytes（64 GiB） |
| pinned tools | SwiftLint 0.63.2、XcodeGen 2.45.4；路径 `/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/macclippy-tools/bin` |
| 最后控制状态 | revision 17，generation 1，`mutation_in_progress=true`、`source_fix_pending=true`；desktop locked（control 证据，本 worker 未操作桌面） |
| 本 worker raw 目录 | `/tmp/astra-source-review-20260925/generation-1/`：`source-identity-check.json`、`environment.json`、`findings.json`、`coverage.json`、`source-manifest-g1.json`、`control-at-handoff.json` |
| executor 目录 | `build/hardening-phase6-20260925/`；报告 `docs/review/astra-e2e-results.md` v0.4 是中间交接，本 worker 只读，未往该 lane 写文件 |

环境核实实际命令为 `sw_vers`、`xcodebuild -version`、`sysctl -n hw.model hw.memsize`、`uname -m` 及上述 pinned 路径的 `swiftlint version` / `xcodegen version`。源码清单同时取 tracked diff 和 `git ls-files --others --exclude-standard`，再与 manifest 合并；阅读使用 `rg`、`nl -ba` / `sed`，未只看 tracked diff。原始 findings 的兼容入口仍为 `/tmp/astra-source-review-findings-g1.json`。

阅读跨越修复启动时点。下列发现的行号固定指向 **generation 1**，当前 working tree 的行号可能已变化。`coverage.json` 保存交接时已偏离冻结摘要的文件及新文件列表；这些变动没有被当作已验证修复。`/tmp` 证据可能被系统清理，root 可按其证据目录所有权归档；报告中的身份、触发和审查结论已写入仓库文档。

## 已确认发现（严重度排序）

### ASR-P1-001 — 真实旧版备份无法通过有钥验证或恢复

- **P1 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- 位置：`MacClippyKit/Sources/MacClippyCore/MacClippyBackup+KeyValidation.swift:225`。
- 触发：提供 base `79e987a` 已生成、使用 migrations 001–008 的有效 format-1 加密备份和正确设备密钥。
- 因果链：`validate` → `authenticateKeyIfPresent` → `validateClipboardBlobReferences` → `validateClipboardRecordReferences` 无条件查询 `representation_refs_auth`。该列仅在本轮 `ClipboardStore+Migrations.swift:153–155` 的 migration 010 新增；备份以 `readOnly: true` 打开，验证之前没有迁移。因此 SQL 准备时报缺列，验证与生产 restore 均失败。此路径检查了 representation 表的 `item_index` 是否存在，却没有兼容 record 表的旧 schema。
- 覆盖缺口：`MacClippyBackupCompatibilityTests.swift:62` 的所谓 legacy 测试通过 `:128–137` 仅修改新数据库的 manifest 版本，没有测试旧 schema。
- Luna 修复请求：按实际 schema 读取旧 envelope，缺失 roster 列映射 NULL，仍执行旧载荷密钥认证/引用检查；不得原地迁移输入快照。增加真实 001–008 的 text/image/spilled-representation 备份验证、安装、重启后载荷可读和输入字节不变回归，并保留错误/缺失密钥失败测试。
- root 已通过源码 worker 的普通 commentary 收到此项，控制文件 revision 6 已指派 Luna 修复；修复未独立验证。发现另存 `/tmp/astra-source-review-findings-g1.json`。

### ASR-P1-002 — 粘贴提交及取消回滚没有持续绑定本次写入的剪贴板版本

- **P1 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- 位置：generation 1 的 `MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector+Injection.swift:115`、`:139`；`MacClippyPasteInjector+Snapshot.swift:106`。
- 触发一：本次剪贴板写入成功后，权限查询或焦点验证回调耗时，其他来源已复制新内容；代码仍执行 snippet 的 `beforePaste` 删除及 Cmd-V，实际粘贴最新剪贴板，而非此前准备好的 snippet。
- 触发二：写入后的版本检查已结束，剪贴板被外部更新，再发生 gate 关闭；`.written` 的失败分支没有传入本次成功写入的版本。`finishFailedWrite` 把任何与 original 不同的当前版本采样为本次拥有的版本，允许旧快照覆盖新复制内容。
- 可重复的隔离回归：在 named-board 的 `validateCommitContext` 回调中 `clearContents` 并写入新用户内容；返回 true 时断言禁止 Delete/Paste，关闭 gate 时断言新内容不被回滚。generation 1 源码不满足这两项。
- Luna 修复请求：成功写入必须返回明确的 owned changeCount；提交前和回滚时均仅接受该版本，禁止用任意当前 changeCount 猜测所有权。保留已接受 Delete+Paste 的提交语义，不能宣称 NSPasteboard 与 OS 事件提交之间具有原子性。
- root 已接收并指派 Luna；当前 `mutation_in_progress=true`，本 worker 暂停相关路径复核，等待新的冻结 generation。

### ASR-P1-003 — 默认性能语料在第五条 spilled 长文本被框架拒绝

- **P1 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。属于验收框架阻断，非生产 capture 丢失。
- 位置：`MacClippy/MacClippyE2EControlRequests.swift:189`；重启校验亦见 `:348`。
- 默认 `run_corpus` 的 index 4（`scripts/e2e/macclippy-phase5.py:607`）生成 65,536 字符文本。生产 `Runtime+Maintenance.swift:160` 提供 spill 回调；`ClipboardStore+Capture.swift:289` 将超过 32,768 bytes 的 representation 存为 `.spilled`。框架仅接受 `.present`，故所有默认 1k/10k/100k corpus 在第五条报 `raw-representation-unavailable`。
- 修复请求：E2E 验证与 restart 验证受限读取、认证并逐字节核对 spilled BlobStore 内容；增加超过阈值的框架回归。不得删除长文本 fixture 或放宽生产阈值规避。已立即向 root commentary 报告。

### ASR-P1-004 — 24h soak 延长请求完全不被消费

- **P1 / CONFIRMED_SOURCE / 动态回归 NOT RUN**；验收框架阻断。
- `scripts/e2e/macclippy-phase5.py:2246–2249` 的 `consume_extend_request` 在请求存在时隐式返回 `None`。真正的扩展处理误缩进在 `consume_stop_request` 的 `return True` 之后（`:2268–2301`），永远不可达。
- `extend-soak` 写入请求并返回“已请求”，运行中的 worker 不更新 24h 目标；遗留文件还会使下一次请求报 already pending。无法以该入口完成同一 build 的连续 72h 观察。
- 已即时通知 root；请求 Luna 修复，增加合法请求、错误身份/权限、超过 72h 拒绝及 worker 接受请求的回归。现有 `test_macclippy_phase5.py` 没有扩展消费测试。

### ASR-P2-001 — 跨 poll 重试会丢弃此前已恢复载荷

- **P2 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- `PasteboardObserverLifecycle.swift:136,159` 每次以 `pending.originalChange` 开始，但 `MacClippyPasteboardReadRetryState.swift:137` 只更新缺失 UTI 集合，不保存 reread 后的快照。
- 同一 generation 初始缺 A、B；第二 poll A 恢复、B 缺失；第三 poll 只读 B，却又以最初 A、B 都缺的快照为底，A 重新丢失。预算结束时仍落库缺失标记。
- 回归建议：真实 named-board lazy providers 分批恢复两个 UTI，并覆盖跨 item 重复 UTI；验证最终全字节、item 顺序及有限重试次数。

### ASR-P2-002 — 分号前快速输入导致 snippet 使用过期 caret 锚点

- **P2 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- `MacClippySnippetExpander+Input.swift:224` 取 `cachedSelection`，只在 `:238–241` 累加 trigger 与 delimiter。生产 focus monitor 200 ms 采样，`noteInputEvent` 仅更新时间，`noteInputText` 使用 no-op 默认实现。
- 在采样位置 0 后快速输入 `hello;sig `，expected selection 为 5，实际为 10，`MacClippySnippetExpander+Expansion.swift:31–37` 取消正常展开。当前 fail-closed 分支未证明错目标删除；影响是正常功能被拒绝。
- 回归建议：采样延迟期间的前置 ASCII/CJK/emoji、连续多个分号、auto/Tab 模式，保留 fresh focus/selection 提交检查。现有测试仅从零位置直接输入 trigger。

### ASR-P2-003 — 旧队列粘贴进度可发布到新会话

- **P2 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- `MacClippy/MacClippyDockModel+QueueActions.swift:45–48` 的 main-hop 进度发布没有 session/operation/token 校验。`:71` 在完成回调校验前清空进度。
- 旧回调已排入主线程后，关闭/重开面板或开始其他操作，会短暂显示旧进度或清除其他会话进度。已检查 `DockModel+Selection.swift:331,358` 的取消及 generation 更新，无法取消已排入的回调。未据此认定发生错误目标粘贴。
- 请求对进度发布和结束清除统一绑定 session、operation 与 token，并增加延迟 main-hop 回归。

### ASR-P2-004 — 1,000 次预览验收的固定 socket 超时不足

- **P2 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- `scripts/e2e/macclippy-phase5.py:1648` 对 `preview-loop` 固定 120 秒；`MacClippyE2EControlUI.swift:122–130` 每次等待生产窗口实际关闭。关闭动画由 `MacClippyDockController+Preview.swift:428` 使用 `MacClippyMotion.swift:26` 的 0.13 秒。
- 当 Reduce Motion=false，1,000 次关闭单独就需要至少 130 秒，尚未计入打开、数据加载和命令处理，故外层会超时。
- 建议有界分批保存进度或按请求次数设置有上限的超时；保持实际生产动画，不以关闭动画代替所请求的验收。

### ASR-P2-005 — 详情 representation 行丢失 native item 身份

- **P2 / CONFIRMED_SOURCE / 动态回归 NOT RUN**。
- `MacClippy/MacClippyRuntimeModels.swift:152` 的 `MacClippyItemRepresentationDetails.id` 仅为 UTI；`Runtime+History.swift:173` 和 `:254` 不保留 itemIndex；`MacClippyDetails+Sections.swift:79` 用其直接驱动 `ForEach`。
- 两个原生 item 含同一个 UTI 时产生重复行 ID，详情无法可靠区分各 item 的字节数/状态。持久化、哈希和 replay 身份并未据此判定失败。
- 请求保留 `(itemIndex, uti)` 身份并明确 item 展示，增加同 UTI、不同 item/状态的详情回归。

### ASR-P2-006 — 非默认 staging 路径可绕过 `.build` 根目录删除保护

- **P2 / CONFIRMED_SOURCE / 动态回归 NOT RUN**；base 已有的问题，属于本轮 release automation 审查范围。
- `scripts/package-dmg.sh:64–66` 在 `STAGING_DIR` 已存在时先进入该目录，再追加 basename。若明确设置为仓库 `.build`，比较值为 `.build/.build`，绕过 dedicated-child 检查；`:140` 的 `rm -rf` 仍使用原始 `.build`。默认 staging 子目录不受影响。
- 请求修正已有目录/未创建目录的 canonical path 处理，并以 disposable fixture 测试根目录拒绝、正常子目录及 symlink containment。本 worker 未执行破坏性命令；root 已在 revision 13 指派脚本 worker。

## 生产调用链及源码结论

以下是静态检查范围与约束，不是运行 PASS。除明确列出的缺陷外，没有把推测升级为确认缺陷，也没有据此作出“无其他 bug”的保证。

| 边界 | 已检查的完整实现和相关生产调用链 | 结论与验收边界 |
| --- | --- | --- |
| SQLite 生命周期与锁顺序 | `PathsDatabase.swift`、`Runtime+Synchronization.swift`、`Runtime+Lifecycle.swift`、`MaintenanceIOCoordinator.swift`、`RuntimeStorageBootstrap.swift`、AppDelegate restore/startup | 独立 reader / backup snapshot 有 admission 与退出记账，`closeForReplacement` 拒绝后续 reader 并等待已接纳 reader；restore 先取消/排空相关工作，再关闭数据库并替换根。直接 `queue.close()` 与 replacement fence 语义不同，后续复审不可混用。未运行并发/TSan。 |
| background I/O 与实际持有资源 | `Runtime+Backup.swift`、`Runtime+Preview.swift`、`Runtime+ImageCompression.swift`、`+ImageCompressionCommit.swift`、`+OCR.swift`、thumbnail loader/scheduler/cache | 慢解码/识别不应占 store lock；生命周期令牌防止过期提交，restore I/O barrier 与 cache retirement 管理根目录更换。取消标志本身不代表已释放 Data；OCR/thumbnail 测试含在旧工作返回前仍占预算的断言。需要实测内存与锁等待分布。 |
| 根级 BlobStore lease | `BlobLease.swift:54`、`BlobStore.swift:58,82,99`、Runtime maintenance/deletion/compression callers | registry 以 canonical root 关联不同 BlobStore 对象；release 将待删 ID 交给回查回调，不自行盲目 unlink。引用新增后必须重新校验；已读跨对象 lease、重新引用、backup/deletion 重叠测试。 |
| 引用认证、删除、回填 | 全部 `ClipboardStore+AttachmentReference*`、`+RepresentationRoster/Validation/Deletion`、`+BlobReferences`、`+DeletionJournal`、`+Retention`、`RetentionPolicy+Storage`、Runtime batch/reconciliation | 读取 record envelope 与 authenticated roster，删除前要求引用索引可证明完整；旧版不完整 spilled catalog 保守保护。排除 record 是 SQL/逐记录排除，不能从共享全局 ID 集合减掉该 record 的 blob IDs。迁移、>256、共享主图/representation、pin、损坏 envelope 的覆盖已读。 |
| capture 数据与入队 | `PasteboardCapture.swift`、`+Reading.swift`、`PasteboardMapping.swift`、observer/controls、`CaptureQueueAdmission.swift`、Runtime maintenance、capture/dedup/store | raw snapshot、映射和落库分别检查 generation/lifecycle；byte/job admission 随实际 retained payload 生命周期释放。发现 ASR-P2-001；超载应有明确结果与受限恢复，不能把数据被拒当作保存成功。 |
| 同步 provider 约束 | `PasteboardCapture+Reading.swift`、`MacClippySystemPasteboardReaderTests.swift:61,126,161`，observer controls / Runtime stop | deadline 只能限制后续 provider 调用和重试；进入同步 AppKit provider 后不能强行打断。已有源码测试真实 named-board provider 的 generation churn、延迟和取消；不构成 stop/close 的硬实时保证，也不代表第三方 provider 全覆盖。 |
| item identity / legacy / replay | representation model、migrations 001–012、store representations、capture hash、Runtime clipboard/ordered/queue/drag/preview/history callers | 持久化与 capture hash 保留 itemIndex / UTI / payload state；legacy 解码和缺失状态已有测试。发现详情 UI 身份丢失 ASR-P2-005。`MacClippyPasteboardPreparation.swift` 首轮完整阅读未完成即进入 affected-path 暂停，须下一代补齐。 |
| snippet 和 paste 提交 | injector/injection/snapshot/gate、全部 expander 分文件、planner/key poster/focus context、Runtime paste/queue、Dock target/key/lifecycle | 已跟踪 gate、fresh context、target PID、accepted Delete+Paste 后输入缓冲与定向重放。发现 ASR-P1-002、ASR-P2-002。真实应用同 PID 的不同 field、mouse/caret、keyDown/keyUp/flags 顺序与提交期间输入仍要实际验证；模拟 context 或事件回调不能证明删除/插入。 |
| stale task / UI 结果 | Dock model actions/batch/queue/utilities/loading/selection、Dock controller lifecycle/animation/key/preview、Settings maintenance、AppDelegate lifecycle | 多数发布点带 session/operation/lifecycle guard；旧 queue progress 存在 ASR-P2-003。页面、预览、OCR、thumbnail late publish 的独立回归已读；没有运行 1,000 次可见周期。 |
| backup / restore | Backup create/snapshot/validation/key validation/restore/file I/O、Settings restore、AppDelegate stop/reopen、process-crash harness 全部文件 | 真实旧 schema 缺陷见 ASR-P1-001。子进程框架确实调用生产安装/恢复，核对 SIGKILL 与请求身份，在新进程恢复后验证数据；不是仅 manifest 检查。文件/目录 fsync 与断电耐久性不由这些测试证明。 |
| search / maintenance | SearchStore 全部相关分文件（含 Terms）、Runtime history/projection/search repair/maintenance/reconciliation、Store batch reads | keyset/page 设计减少返回集，但 `LIMIT` 不自动限制扫描工作量。下文的 malformed health scan 风险尚需 100k 实测；RuntimeScale 的单次 30 s 断言不等于 p95 100 ms。 |
| release automation | `.github/workflows/ci.yml` / `release.yml`、Makefile、verify-required-ci、select-release-version、retarget-nightly-tag、release、archive-signed、metadata/packaging 及新 shell 回归 | gate 绑定 workflow ID/path 与精确 head SHA，完整分页后选择最新 attempt；main-only nightly 与静态 concurrency group、显式 force-with-lease 已检查。发现非默认 staging 删除保护 ASR-P2-006。没有调用 GitHub、更改 tag 或发布。 |
| E2E 与 soak 框架 | E2E isolation/fixture/control/recipient/keychain/metrics/UI 全部分文件、Swift launcher、C sampler、Python runner 与 Python tests | 发现 ASR-P1-003/004、ASR-P2-004；source-format 与 primary-kind 必须分开；AppKit 合成 text primary 不应改变生产 format priority。当前 E2E/soak 修复范围已暂停，必须下一代完整复核。 |

## 测试覆盖的强项、缺口与待测风险

1. **确实经过生产组件的覆盖**：SystemPasteboardReader 的真实 named-board provider；App backpressure/Runtime capture；同 root 不同 BlobStore 的 lease；search repair 与 capture 重叠；close 后读连接拒绝；retention/deletion journal 和共享引用；spilled payload / native item replay；restore child-process kill/restart。测试源码已读，本 worker 执行均 `NOT RUN`。
2. **restore child 测试的证明范围**：`MacClippyBackupProcessCrashTests.swift:11,46,81,117,153` 遍历 install、staged move、rollback/cleanup、finalize；`RestoreCrashExecutionVerifier.swift:19,37` 核对 SIGKILL 和新恢复进程；`MacClippyBackupProcessCrashStorageVerifier.swift:40` 校验全 old 或全 new 的 records、payload、search、pinboard/snippet、组件形状与 journal 清理。fixture 使用 disposable key。成功后临时 child 证据随 workspace 清理，最终执行应保存足够 checkpoint/identity 原始记录；不要仅引用测试名称。初期 marker-only transaction tests 的证明弱于这一组。
3. **测试名称不能充当覆盖证明**：`MacClippyRepresentationCaptureRollbackTests.swift:115` 的 sentinel 测试仅检查 store/representation，没有驱动 sentinel；`:130` 的 reconciliation 测试只检查引用 ID，没有实际执行 reconciliation。另有 RuntimeBatchOperations 测试在测试内复算“是否完整成功”，不能独立证明 Dock 的反馈路径。现有真正 observer/sentinel 与 reconciliation 集成测试须分别计证据。
4. **recipient 插入缺口**：Copy/Queue/PasteResult/Transform 测试多为 named-board 内容加假事件计数。队列末板内容不证明前面每条已插入； `.injected` 是注入接受语义。内部 fake recipient 仍不是 TextEdit/Safari/Terminal/Finder。最终 fake recipient 必须逐 item 保存 native bytes，真实 interop 必须检查接收结果与顺序。
5. **待测性能风险，不是已复现延迟 bug**：`SearchStore+RepairPages.swift:62` 的 malformed-row 查询以 `LIMIT` 限制异常行输出，healthy rows / join / union 仍可能扫描全历史，且 `Runtime+SearchRepair.swift:342` 调用处持 Runtime lock。需测 100k 健康库、损坏库的锁持有时长、并发 capture/search 和可见卡顿；不能仅用返回 1 条 error 宣称有界。root 已登记此风险。
6. **shipping 测试入口尚不能判 PASS**：App `Runtime+ClipboardTestSupport.swift` 和会改行为的 MaintenanceIO hook 有 DEBUG 条件，E2E 文件/flag 在项目配置中单独隔离；但 package 中若干 `ForTesting` API、observer controls、`MacClippyThumbnailDiskCacheTestHooks` 并未整体用 DEBUG 包围。需要最终 shipping 配置与可执行文件核实可达测试入口、控制端点及链接结果，不把“E2E bundle 不同”当成全部 test seams 排除证明。未确认生产可触发漏洞，按发布验证缺口记录。
7. **soak 证明不足**：generation 1 workload 主要是 text/HTML/RTF capture + search + writer contention；缺少覆盖所有 image/files/OCR/delete/backup/reconcile 行为的证明。search 日志只记录 hitCount 不等于断言预期 recordID，runner error 计数也不等于产品诊断错误计数。root 已把 stable recordID/native payload 与 mixed-result/error 断言列入修复，最终需按新实现定义实际负载范围。24h/72h 均未启动。
8. **剩余非确认风险**：legacy v1/v2 representation-roster 的真实历史 fixture 兼容边界、preview/root replacement 时的读取消、旧 main workflow rerun 可能将 nightly 指回较早 SHA，均未取得可重复产品故障证据；不得作为已复现 P1。nightly 的 main-only 与串行化本身已实现，不额外假定“只允许最新 main SHA”的未定义策略。
9. **系统事件边界**：信任回调、模拟通知和 synthetic context 只能计模拟回归；没有更改 TCC、锁屏或显示配置。macOS 14 deployment target 保持 14，实际 runtime `NOT RUN`（用户明确无环境），不再申请新 host/CI。旧工具链不能编译 GRDB 的事实不证明现有产物不能运行在 14。

## 初始验收矩阵（本 source worker）

`FAIL (SOURCE)` 表示存在确定源码缺陷，不是伪造了运行失败；`NOT RUN` 是本 worker 未执行。executor v0.4 已另报 generation 1 的 Package/App 默认 suite 及独立 sampler audit；其原始日志未在本轮逐项复核，不能覆盖修复后源码或填平以下缺口。

| 编号 | 用户要求的场景 | 本轮状态 | 后续最小证据 |
| --- | --- | --- | --- |
| 1 | 生产 capture → persistent restart → search → normal/plain；text/CJK/emoji/HTML/RTF/image/files、多 item / 重复 UTI | NOT RUN；框架 FAIL (SOURCE)：P1-003 | 同 recordID、原生 item 顺序、逐字节/hash、spilled 解密、plain 派生值；分开 requested sourceFormat 与 observed primaryContentKind |
| 2 | 新 TextEdit 文档、新 Safari local page/window、新 Terminal window、隔离 Finder files/folders | BLOCKED | desktop locked；未建立 installed app 正常 capture-pause 隔离。不得写 `.general`，process-local sentinel 不保护 installed app。解锁/暂停由 root 协调，恢复 prior state，不覆盖更新的用户 copy |
| 3 | churn、延迟/缺失 provider、oversize、预算、混代拒绝、显式 overload | NOT RUN；FAIL (SOURCE)：P2-001 | 真实 named-board providers 分轮恢复、item identity、实际 retained bytes、取消后不发布、有限尝试；同步 provider 的软预算限制说明 |
| 4 | 跨 app/field snippet、mouse/caret、queued typing、Esc、stop/close/reopen、accepted commit | NOT RUN；真实 UI BLOCKED；FAIL (SOURCE)：P1-002/P2-002/P2-003 | 早期目标变化、同 PID field 变化、快速前文、删除/插入接收结果、keyDown/keyUp/flags 顺序和绑定；不能只统计 post callback |
| 5 | 实际 AX missing/revoked/restored、sleep/wake、lock/unlock、screen changes | NOT RUN | 标记实际事件或模拟，未经协调不改变用户权限/屏幕；不可把 fake trust 计为真实授权 |
| 6 | 正常/旧版/缺文件/等长损坏/错误或缺 key；每个 I/O 边界和 child death/restart | NOT RUN；FAIL (SOURCE)：P1-001 | 真旧 DDL 只读验证、正确 key reopen 内容、all-old/all-new 与 payload readability；process crash 与 power-loss 分开 |
| 7 | >256 删除、共享附件变体、pins、迁移/backfill、并发 reconciliation/search repair | NOT RUN | 实际受保护 ID/payload 不丢，损坏索引 fail-closed，搜索修复收敛，锁/可见 stall 分布 |
| 8 | 1k/10k/100k mixed history、1,000 实际 panel/preview cycles、Release timing/resources | NOT RUN；框架 FAIL (SOURCE)：P1-003/P2-004 | corpus 实存 ID 数等于请求数；seed 20260925 中 14485/53930 独立图像身份；逐样本与 p50/p95/p99、RSS/physical/CPU/wakeups/queue bytes/WAL/writes，unsupported 标 unavailable。warm panel p95≤100 ms、10k search≤100 ms、100k≤200 ms 仅为 TARGETS；DB-only 单列 |
| 9 | full Package/App、actual opt-in RuntimeScale、TSan、Swift 6 Release、shipping seams、macOS 14 | 本 worker NOT RUN；macOS 14 NOT RUN | root 下一代 exact source/app hashes；普通 App 始终 `-only-testing:MacClippyTests`；RuntimeScale 两个 env flag、实际 executed>0 且零 skip；最终 Release 要显式 Swift 6，CI 的 Debug Swift 6 与普通 Release 两步不能合并当成 Swift 6 Release 执行 |
| 10 | durable harness smoke 后经 root 协调的 24h 和连续 72h | NOT RUN；框架 FAIL (SOURCE)：P1-004 | detached worker 接收 extension、active workload/结果断言、liveness/errors/crashes/睡眠缺口、source/build/corpus identity；任意实现修复重置观察窗口，smoke/空等不算 soak |

## 下一冻结代次的精确复审范围

必须先读最新 control，并由 root 提供新的 manifest / Release app。仅在 `mutation_in_progress=false`、`source_fix_pending=false` 的新 generation 上复核；先全量 hash，再十项修复与调用链，再 executor 证据。当前 generation 1 app 不能承载下一代结论。

- 十项问题的全部 path、Luna 新测试及相关调用者：old-schema backup validation/restore、owned pasteboard generation 和失败回滚、capture retry 累积、snippet caret anchor 与上下文、防 stale queue progress、details item identity、spilled/native E2E proof、soak extension/负载断言、preview timeout、package path containment。
- E2E 再核对两个 poster 都被覆盖，显式 target PID 只命中 fake recipient；Dock hide/reopen 始终自目标；PNG 用完整 digest、actual captured unique IDs；RTF 同时验证 decoded text 与 byte-exact rich representation，不改变生产 priority。
- 下列首轮阅读未完整完成就进入 affected-path 暂停，不能称已审完：`MacClippyPasteboardPreparation.swift`；Platform 的 `MacClippyPasteInjectorTests`、`MacClippyPasteInjectorTargetTests`、`MacClippyPasteboardObserverLifecycleTests`、`MacClippySnippetExpanderContextCancellationTests`、`MacClippySnippetExpanderRestoreTests`、`MacClippySnippetExpanderTestSupport`、`MacClippySnippetExpansionPlannerTests`、`MacClippySnippetInputCommitTests`；App 的 `MacClippyE2EBuildIdentityTests`、`MacClippyQueuePasteModelTests`、`MacClippySnippetTests`；完整 generated `project.pbxproj` 的 target/build settings 对应关系。其余重点修改/新增实现已阅读完整文件并沿调用链检查，测试覆盖检查见上表；这仍不是最终整个 working tree 的完整审查声明。
- `coverage.json` 还保存本轮结束时新增或 hash 改变的文件。修复期间出现的新 `MacClippyBackupHistoricalSchemaTests.swift`、`MacClippyPasteInjectorGenerationOwnershipTests.swift` 等须在下一代首次独立检查；列表是快照，不能代替下一次重新枚举 untracked files。
- 对至少 100k 健康库的 malformed health scan 持锁测量、shipping test seams 排除、真实 app interop、真实系统事件，以及 24h/72h，保持未完成状态直至对应证据到位。不要为缩短等待而改弱测试。

本轮没有 pending worker / UI / 临时产品进程需要清理；没有长期任务已启动。`astra-final-review.md` 尚未生成，最终接受结论留给新 generation 的独立复审与实际验收。

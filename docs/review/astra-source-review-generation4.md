**Generation 4 独立源码审计：审查完成，最终发布验收不通过。**

审查者：Astra。日期：2026-09-26（UTC）。本轮确认 **P0=0、P1=0、P2=2、P3=1**。generation 3 的控制 socket P1 崩溃和 P2 小缓冲区截断问题已通过独立实际 Release 进程测试关闭。新的两项 P2 属于存储维护正确性问题，P3 属于 CI lint 门禁缺口；均未修改源码。建议交回 root/Luna 修复两项 P2、补齐回归，并处理 P3 后重新冻结验收。

这是完成全工作树盘点、生产调用链语义审查及授权范围内独立 E2E 后的结论，不沿用 generation 3 的“P1 提前停止、完整审查未完成”状态。它也不表示所有运行环境、UI 路径或长期行为均已验证。Full Package TSan 仍是有明确失败记录的宿主限制；macOS 14、GUI/接收应用互操作、权限/生命周期 UI、24h/72h soak 均为 **NOT RUN（未运行）**。详见配套 [E2E 报告](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/astra-e2e-results-generation4.md)。

**冻结身份、范围与保存性**

| 项目 | 独立核验结果 |
|---|---|
| HEAD / 冻结 base | `79e987a982f15f9193392c9af98b66465efd5ee2`，分支 `codex/core-reliability-hardening` |
| Canonical inputs | **520** 个，合计 **5,231,201 bytes**；逐项路径、长度、SHA-256 与 canonical manifest 一致 |
| sourceContentSHA256 | `31d1ecf48be82594bf35fb5b74e85b8fd4947d3ae8a265d23dd787c220148b2c` |
| manifest 文件 SHA-256 | `23e902f1e22d5be0f30c58b5d7514a6ffbe4a6c27f682593bef0dc103c51ff73` |
| 初始工作树 | 112 个 tracked changed、160 个 untracked；staged=0。它们是交接时已有内容，不是本轮修改 |
| generation 3 → 4 | 5 个输入差异：控制服务器、实际传输实现、读测试、两个新增的 accepted/write 测试文件 |
| 审计前后 | 520 输入、manifest、两份 App executable 哈希不变；已有工作树文件字节不变；git 可见新增仅本轮两个报告 |

独立脚本重新枚举 git tracked 与非 ignored untracked 文件，按 canonical 输入选择规则读取全部文件，自行计算排序、紧凑 JSON entries 的摘要，未调用 Luna 的 manifest 计算函数。完整工作树差异、staged 状态、untracked 文件及 canonical 外的 README、工程文档、既有报告和已有 Python 缓存也纳入库存。没有执行仓库文件内的代理指令；这些文件仅作为证据。

证据：[verify_frozen.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/verify_frozen.py)、[identity-before.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/identity-before.json)、[identity-after.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/identity-after.json)、[全 520 输入扫描](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/all-520-input-scan.json)、[完整 tracked diff](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/tracked-full.diff)、[初始库存](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/inventory-before.json)、[最终保存性证明](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/preservation-final.json)。自动扫描、语法检查和哈希证明覆盖范围及身份，语义判断来自下文的跨文件调用链审查，不能将前者等同于形式化正确性证明。

| Release artifact | executable SHA-256 | bundle / 架构 |
|---|---|---|
| `ReleaseE2EDerivedData/.../MacClippyE2E.app` | `5badd1a4c78177fab207f866c0b5fa0054ce60edc95e91cf502425a91712a592` | `com.macallyouneed.macclippy.e2e`；1.0.0 (1)；arm64 + x86_64 |
| `ReleaseShippingDerivedData/.../MacClippy.app` | `2b748bfa6835962b8a91f14c4a11caa2e32518370bd0d60a48b4fed49c049059` | `com.macallyouneed.macclippy`；1.0.0 (1)；arm64 + x86_64 |

两者 `LSMinimumSystemVersion=14.0`；E2E 内嵌配置为 Release、内嵌 source digest 与上述 520 输入完全一致。实际执行的是 arm64 E2E，Shipping 只做静态身份检查，x86_64 仅验证 slice 存在。最低部署版本字段不构成 macOS 14 运行通过证据。本轮使用交接的已冻结 App，另行编译自己的 harness，没有声称重新构建 App。

**P2 — ASR-G4-P2-001：schema 011 的合法 v1 附件清单迁移后被维护认证误判为损坏**

状态：**OPEN，独立复现**。影响为合法历史记录的 retention/重新认证维护失败；没有观察到此用例的内容丢失，也没有发现它阻止普通读取或整个 App 启动。不是 generation 3 socket 修复引入的问题。

复现使用冻结 Release 的 `MacClippyCore.o`、`GRDB.o`，由 Astra harness 调用生产 migration 的前 11 项建立真实旧 DDL（没有 `item_index`），写入合法 AES-GCM record envelope、表示 payload 和 **version=1** 的认证 roster，再标记其引用已验证。SQL 只用于构造历史格式；迁移、读取和维护均调用当前生产 API。

1. 当前 `ClipboardStore` 打开旧库，生产 migration `012-pasteboard-item-identity` 成功执行。
2. `playbackSnapshot` 返回完全相同的正文和表示字节，证明不是错误密钥或损坏 fixture。
3. `RetentionPolicy(maxItems: 0).enforce` 抛出 **`invalidStoredRecord`**，记录数仍为 **1**，预期应删除该合法且未保护记录。
4. 通过现有 SQL trigger 将该行的 verified marker 失效后，`authenticateOwnedBlobReferenceIndex()` 也抛同一错误；正常 playback 仍精确一致。

根因位于 [AttachmentReferences.swift:267](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore+AttachmentReferences.swift:267)：289 行先按当前 schema 默认构造 **v2** roster，291 行打开已认证的旧 **v1** roster，295 行直接比较整个结构。即使所有 item index 都是 0、所有 payload 摘要和引用均相同，也会因为 `version` 不同失败。347 行的辅助函数没有传入旧 roster 版本。相对地，正常读取的 [RepresentationRoster.swift:157](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore+RepresentationRoster.swift:157) 在 171 行明确用 `expected.version` 生成待比较结构，所以读取通过。

受影响生产链：`Runtime.enforceRetention` → `authenticateOwnedBlobReferenceIndexForRetention` / `RetentionPolicy.deleteRecords` → [authenticateRetentionCandidates:11](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore+AttachmentReferenceAuthentication.swift:11) → `authenticateAndVerifyAttachmentReferences`。未验证的旧 v1 行还会阻止 `runStorageReconciliation` 的引用认证。Runtime 会捕获维护异常并记录 degraded reason，因此本次定级 P2；未将“维护失败”扩大描述为 App 必然不能启动。

现有 historical-schema 回归重点覆盖 schema 008、缺少 roster 的更早格式，未覆盖这个已经具有合法 v1 roster 的 010/011 → 012 边界。建议按已认证 roster 的版本验证；若升级到 v2，应在认证成功后事务化持久化，保留错误密钥、被篡改引用和 payload 必须拒绝的语义。加入真实 010/011 fixture 的读取、retention、marker 失效后 reconciliation 回归。

证据：[storage_edges.swift](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/storage_edges.swift)、[独立 runner](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/run_storage_edges.py)、[原始结果](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/storage-edges.stdout.jsonl)、[退出与清理](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/storage-edges-result.json)。实际历史记录 ID：`01M3EEKY47G0W3CSJPQ2A0BJ0D`。

**P2 — ASR-G4-P2-002：图片配额对共享 primary blob 重复计费，提前删除历史记录**

状态：**OPEN，独立复现**。通过公开生产 API 写一个 4,096-byte 图片体（加密文件 **4,124 bytes**），再创建两条引用同一个不可变 blob 的图片记录。没有 SQL 注入记录，也没有篡改引用。配置 `maxImageBytes=4124`，真实唯一图片存储恰好等于上限，预期两条记录均保留；实际 **2 → 1**，较旧记录被删除，幸存记录引用的 blob 仍在。

根因：[RetentionPolicy+ImageCap.swift:57](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/RetentionPolicy+ImageCap.swift:57) 逐条 image record 累加 `byteSizeChecked`，67–69 行不去重 blob ID；计划和提交后又按每条记录的字节数递减 remaining（115、145 行）。因此同一个实际文件被多次计费，即便删除某个 owner 并未释放文件也被当作释放空间。`TotalCap` 的唯一引用统计并不能修复独立的 `ImageCap` 分支。设置页的 `Runtime.storageUsageImageBytes` 则通过 [indexedImageBlobIDs](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore+IndexedImageBlobIDs.swift:8) 的 SQL UNION 按唯一 blob 计量，也与该删除策略的重复计量不一致。

生产链：`Runtime.enforceRetention` → `RetentionPolicy.enforce` → `enforceImageCap` → `deleteRecords` → 引用认证/删除 journal。复现中的 shared blob 保留，故不是“幸存记录图片损坏”；损失是配额尚未实际超限时提前移除旧历史。共享引用是 Core API 支持的数据形态，普通 capture 往往新建 blob 或去重记录，本报告不声称所有日常图片捕获均会触发。

建议按唯一实际 blob 统计；仅在最后一个有效 owner 被删除、文件确实可以回收时抵扣字节，包含 pinned/其他表示共享引用的情况。回归应断言“配额等于唯一字节时零删除”，以及跨批次/受保护共享 owner 的计量。复现 IDs：旧 `01M3EEKY4VTQ4KMT9EM8ZSXHG8`、新 `01M3EEKY4VYVWT1RBTE056G09A`。harness、原始证据和清理与上一项相同，原始事件名 `shared-image-cap`。

**P3 — ASR-G4-P3-001：干净 CI 检出不执行 strict changed-file lint，新增 warning 可放行**

状态：**OPEN，独立复现**。当前 generation 4 的实际 strict lint 零违规结果仍成立；发现的是未来 CI 门禁行为缺口。

[scripts/lint.sh:43](/Users/mingjie/Documents/github/personal-projects/mac-clippy/scripts/lint.sh:43) 的全量 baseline 检查没有 `--strict`；只有 changed-files 非空时 68 行才执行 strict。61–62 行只枚举 unstaged diff 与 untracked，遗漏 staged，更不会在干净的 CI checkout 中获得已提交改动。[ci.yml:75](/Users/mingjie/Documents/github/personal-projects/mac-clippy/.github/workflows/ci.yml:75) 直接调用该脚本。

独立 fixture 在 0700 临时根复制**未修改**的 `lint.sh`，使用空 baseline、仅 trailing-whitespace 规则及一个产生 warning 的 Swift 文件；只将只读 git diff/ls-files 模拟为干净 checkout。调用固定 **SwiftLint 0.63.2**：实际脚本退出 **0** 且有 warning，同一 fixture 加 `--strict` 退出 **2**。工具 SHA-256 `2991cdee904be388d6d15e9cea560c3d6b0d8c009462b8261ed608709b7712c7`；不是用机器上另一版本推断行为。

建议全量 baseline pass 使用 strict；若保留局部检查，补 staged 与 CI 提交范围，并加入干净 checkout/staged 的 warning 回归。证据：[lint_gate_probe.py](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/lint_gate_probe.py)、[lint-gate-result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/lint-gate-result.json)、[脚本原始输出](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/lint-gate-clean.stdout.log)、[strict 原始输出](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/lint-gate-strict.stdout.log)。临时根已清理。

**generation 3 socket 问题关闭证据与当前生产路径**

| 旧 finding | 本轮结论 |
|---|---|
| `E2E-G3-P1-001`：11-byte partial JSON peer close 后进程退出 | **指定缺陷关闭**。实际 Release accepted socket 重复 8 次，逐次 ping 健康，PID=66529、lock device/inode 不变，没有以重启掩盖崩溃 |
| `E2E-G3-P2-001`：1 KiB draining receiver 截断大响应 | **指定缺陷关闭**。实际 RCVBUF=1024 与默认实际 8192，分别延迟 250 ms 开始读，均收到完整 66,183-byte newline JSON；内含 65,536-byte 原始文本长度/哈希完全一致，约 0.26 s 完成 |

[服务器:243](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:243) 的 socket 创建、`F_GETFL/F_SETFL(O_NONBLOCK)`、bind、chmod、listen 都检查返回值；accepted fd 的 flags 设置失败即 close。旧的 ignored `setsockopt(SO_NOSIGPIPE)` 已从 accepted 路径移除。所有响应，包括 EOF/无效请求后的错误响应，都走 [生产 writeLine:58](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyUnixSocketLineTransport.swift:58)：每次 `Darwin.send` 均传 **`MSG_NOSIGNAL`**，不是依赖初始化时可能失败的 socket option。

`SO_SNDLOWAT=1` 是有返回值检查的必要 write-readiness 配置，失败会在第一次 send 前返回 false。小 receive buffer 下 poll(POLLOUT) 的低水位条件因此可以继续推进。partial send 递增 offset；EAGAIN/EWOULDBLOCK 进入 poll；单调时钟剩余预算在 poll 重试/EINTR 后重算。读端保留跨 EAGAIN 的片段、受最大字节数限制，server 单次 read/write 等待预算各 10 s。本轮实际 read timeout 为 10.001999 s，独立生产 transport 的 no-reader 80 ms budget 在 82.011 ms 返回 false，poll EINTR 注入在 82.251 ms 超时；没有将这些测量扩大成所有 handler 都有端到端绝对超时。

fd 所有权也审查到实际调用方：监听 fd 的 DispatchSource cancel handler 在自己的串行队列关闭；stop 先失效 descriptor、取消 source 并移除私有 socket 路径。accepted fd 在无效请求分支或正常 response 完成分支各自 close 一次，发送在后台队列执行。stop 不主动取消所有已接受 handler；其 I/O 等待有界，handler/系统提供者的完成仍是独立边界。private 0700 root/0600 socket 是隔离前提，未把此 E2E 服务视为对不可信用户开放的网络服务或证明无限并发下的资源上限。

新 XCTest 的 accepted/write 用例调用实际 production transport，覆盖不完整连接关闭、后续健康连接、small buffer、partial write 后关闭及超时；它们不是只测自写的模拟 sender。Astra 又将**未修改的生产 transport 文件**编入 TSan harness，17 个断言场景全部通过、stderr=0、所有 owned fd 在 close 后检查 EBADF。实际 App E2E 则补上 XCTest helper 不包含的 `MacClippyE2EControlServer.receiveAndDispatch → invalid-request → send` 路径。证据见 [socket-probe-tsan.stdout.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/socket-probe-tsan.stdout.jsonl) 和 [实际运行 events.jsonl](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-e2e/run-c0b8aed3-cded-402a-b287-35829832721b/events.jsonl)。

**全工作树语义审查覆盖**

520 输入按顶层分布：`.agents` 5、`.github` 2、`.gitignore` 1、lint baseline 1、Xcode project 5、App 161、Package 256、App tests 53、UI tests 1、Makefile 1、project.yml 1、scripts 33。除本代 5 个 socket 差异外，审查延伸至下列完整生产流程及相关现有测试的断言边界。这里的“审查”表示源码/调用关系和证据分析，不表示每个分支都由本轮动态执行。

| 范围与入口 | 审查结果、错误/并发边界 |
|---|---|
| `MacClippyAppDelegate+Startup/+Lifecycle/+BackupRestore` → `RuntimeStorageBootstrap` → `Runtime+Lifecycle` | 初始化时 paths/keychain 依赖与已有库密钥缺失处理；start/stop 生产者、timer、通知、snippet owner；restore 前 off-main drain 与数据库关闭、失败后的 reopen。普通 stop 的 generation 失效不等于等待所有本机调用返回，replacement 才走 drain/lease barrier |
| `Runtime+Synchronization`、capture admission、OCR/AsyncOperation | lifecycle commit/store/state 锁序与 token 校验；8 capture jobs/256 MiB、4 倍估算预留；OCR 8 jobs/64 MiB、2 workers。取消后仍持有原生任务数据时保留 reservation，不把 cancel 标志当作立即释放内存。overload/deferred recovery 与 shutdown generation 分开处理 |
| `PasteboardCapture+Reading` → observer retry/lifecycle → Runtime.capture | changeCount 前后 fence、同 item/UTI 重试结果累积、三次 native read 尝试与 admission/recovery；原生 provider 可能阻塞，预算只能约束其前后和重试，不能抢占 OS 调用。named-board synthetic 真实读取动态覆盖，general board/睡眠恢复 UI 未执行 |
| `ClipboardStore+Capture/+Representations/+CaptureDedup` | record envelope、roster、normalized reference marker 事务；spill 失败补偿；dedup 认证后 CAS modified/envelope/roster；来源/表示/item identity 保留。没有将 payload hash 的 self-report 单独当作 round-trip 证明，E2E 另读 named board 对照 |
| `MacClippyCipher`、DeviceKey、`BlobStore`、`BlobLease` | AES-GCM 认证、已有存储缺钥时拒绝创建替代密钥；不可变 blob、原子安装、安全 ID、root/per-blob lease、延迟删除。20 MiB 新测试正向 round-trip、错误密钥和篡改均被拒绝；retention 后 record/index/blob 均删除 |
| migrations 001–012、roster codec、reference authentication/queries | wrapped/legacy 解析无静默降级，旧无可信 spilled 引用保守保留；normalized 索引须经过认证后才能用于破坏性操作。发现 v1→v2 维护误判，见 P2-001；不能以新格式测试通过推断所有旧格式迁移通过 |
| retention age/count/image/total、DeletionJournal | 分页选候选、pin 保护集合重新读取、footprint/modified 校验、commit fence、持久化待删除 journal 与 secondary cleanup 重放；错误密钥不能凭旧 verified marker 获得删除许可。ImageCap 共享字节错误见 P2-002 |
| SearchStore / structured query / Runtime history / SearchRepair | SQL 参数绑定、FTS 词项限制、keyset/page limit、revision/repair epoch、水位 CAS、分批 materialization 与取消；repair 期间旧索引继续可查。LIMIT 约束返回数量不保证公共词检索只扫描 50 行，100k common-term 实测也明显慢于唯一词 |
| reconciliation / storage health | Bloom 候选后有实际引用检查，删除前 Runtime fence 再验证，避免 capture 与孤儿删除竞态；repair-needed marker 和失败可观测。bounded health 的快速 schema 检查不同于 full integrity；完整检查使用 reader lease，不夸大健康结论 |
| backup create/snapshot/file I/O/validation/key validation/restore journal | Runtime snapshot 一致性、blob root lease、off-lock 分块复制与取消、路径/checksum/AEAD 校验、stage 后 migration、install/rollback/finalize journal 及启动恢复；历史 schema 008 特例仍保留。已有 crash-child 测试证明相应进程终止边界，不证明断电时所有目录 fsync 的持久性 |
| Runtime edit/labels/transform/compression | search 更新失败时正文/roster 补偿与修复标志；引用 snapshot、blob lease、昂贵解码 off-lock、generation/modified/pin 校验后提交；obsolete blob 清理失败不能伪装成提交成功之前的 rollback |
| Pinboard / Snippet stores、保护 ID、lookup snapshot | 列表只跳过明确可分类的坏记录；crypto/open 错误不悄悄等同空列表；破坏性操作使用 strict protection，避免坏 pinboard 使历史误删；snapshot 更新生命周期与存储错误传播 |
| Paste injector → preparation/snapshot/injection gate/target | owned changeCount、失败 rollback 仅还拥有该代、慢 AX 后 final fence、target PID；Delete/Paste 已接受的成对操作。验证到实际 preparer/调用者，不把控制 socket 捕获当作 OS paste 成功 |
| Snippet expander lifecycle/deferred input/focus AX/key poster | tap 的 unretained owner 生命周期、deferred worker 强引用直至 replay 完成、停止/重新开始 token、FIFO keyDown/keyUp/flags、UTF-16 caret 与 surrogate decoding。未运行真实 AX/TCC/event tap |
| Dock controller/model/actions/queue、详情、card/file thumbnail | session/operation token 与 endSession 失效、stale callback 禁止修改新会话、itemIndex 明确；old Flight waiter 只影响原 flight；file thumbnail 2 workers/64 pending、cache 48/32 MiB、取消执行中的 slot 不过早复用，disk cache retire 与 root barrier |
| SwiftUI/settings/menu/presentation、preview/error 文案 | 接入生命周期、主线程状态、typed error 映射、来源/表示身份和预览资源调用边界。布局及交互仅静态检查；没有声称视觉、可访问性或真实接收应用验收 |
| project.yml、已检入 generated pbxproj/schemes/plists、Package.resolved、Makefile | Shipping/E2E 编译条件与 source phase；版本元数据、universal slice、固定依赖与 warnings 配置。两个 lockfile 同为 GRDB 7.11.1/revision `b83108d10f42680d78f23fe4d4d80fc88dab3212` |
| 全部 CI/release/build 脚本及其测试、工程文档 | exact-SHA required CI 检查、workflow ID/path、分页和最新 attempt、release 版本选择、nightly force-with-lease、staging 删除边界、元数据校验；离线测试只运行检查过的 mocks。发现 lint P3，未做真实远程发布或签名操作 |

加密边界需要明确：body/raw representation/blob 使用认证加密；SQLite FTS、preview、OCR/搜索元数据、标签等不是整库加密。README 的既有说明与实现一致。本轮没有把“密钥正确才能解密原始内容”表述为“磁盘上不存在任何可读文本”。

生成工程静态审计记录 Shipping 132、E2E 143、App test 53、UI test 1 个 App target source entries；独立 `swiftc -frontend -parse` 检查 **453 Swift**（包含 Package.swift 与 launcher）、`bash -n` **33 shell**、AST parse **2 Python**，零语法失败。这里 453 与 lint 的 451 统计口径不同。证据：[generated-project-and-static-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/generated-project-and-static-audit.json)、[独立语法检查](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/independent-syntax-checks.json)。

arm64 Release 符号审计中，Shipping 没有 E2E control/isolation/recipient 符号，E2E 有对应符号；`appendTestRecord` 两者均没有。仍存在 `startForTesting` 和 thumbnail test-hook 符号，审查到正常初始化不会提供这些 hooks，未发现对外配置入口；因此没有写成“所有测试接缝都已剥离”。[release-symbol-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/release-symbol-audit.json) 保留实际计数与原始 nm 输出路径。

**既有证据核验、跳过项与本轮新增执行**

所有 gate 引用的 19 个原始文件/引用项哈希均匹配，逐条解析 XCTest terminal event 后得到下表。测试总数包含 skipped，不能写成 648 或 420 项全部实际通过。日志中的 OS sandbox/linkd 信息不作为测试断言失败计数；实际失败另列。[raw-gate-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/raw-gate-audit.json) 给出文件哈希、每个事件的日志行号和汇总。

| 既有 gate | 经原始证据核验的结果 | 本轮是否重新执行 |
|---|---|---|
| full Package，G4 | 648 = **644 passed + 4 skipped**，0 failure，7.762 s | 否 |
| full App，G4 | 420 = **418 passed + 2 skipped**，0 failure，17.043 s | 否 |
| App TSan，G4 | 420 = **418 passed + 2 skipped**，0 failure，28.997 s | 否 |
| focused socket，G4 | 8 passed，0 skipped/failure | 另行执行独立生产 transport TSan 和实际 App，不冒称重跑同一 XCTest |
| filtered Package socket TSan，G4 | 8 passed，0 failure | 同上 |
| strict lint，G4 | 451 文件，0 新违规；现有 baseline 含 **465** entries | 复核原日志；另做 CI warning fixture |
| universal Shipping/E2E Release build，G4 | 两份 `BUILD SUCCEEDED`，实物身份独立核验 | 未重建 App |
| Release E2E，Luna G4 | 原始 result PASS，哈希匹配 | **另外完成 Astra 自写 orchestration**，见配套报告 |
| Runtime 10k，G3 复用 | 1 opt-in Runtime 用例 passed，4.194 s | 沿用并注明，未当成 G4 新执行 |
| full Package TSan，G2 历史运行 | **FAIL / host limitation**：640 = 632 passed + 4 skipped + **4 failed tests**；94 failure assertions（1 unexpected）；73 interceptor initialization errors | 按用户约束未无谓重跑，绝不写 PASS |

Package 四个 skip 是 child-worker 专用入口、10k observer lifecycle opt-in、100k scale opt-in、20 MiB representation opt-in；App 两个 skip 是 Runtime 10k opt-in 和真实 session event tap opt-in。Astra 的独立 Core 100k 与 20 MiB 覆盖不能把这些原 XCTest 的 skip 改写成已执行。真实输入 tap、10k observer start/stop 本轮未运行。

full Package TSan 的四个失败用例分别为 `testChildDeathAfterFinalizeKeepsAllNewComponents`、`testEveryInstallBoundaryRecoversAfterChildProcessDeath`、`testEveryRollbackAndCleanupBoundaryResumesAfterChildProcessDeath`、`testStagedMoveChildDeathAfterDestinationRemovalRecoversEachComponent`。它们伴随 crash-child sanitizer/interceptor 初始化失败；本轮没有据此确证新的产品 P1，也没有将环境限制当作通过。普通 Package 的这些恢复测试是通过的，两类证据须同时保留。

本轮新增执行：独立 Release E2E（11 captures / 19 representations，真实进程重启与直接 AES-GCM blob 验证）、17 场景生产 transport TSan、100k mixed Core store/search、20 MiB 加密表示正向/错误密钥/篡改/retention、两项存储边界复现、CI lint fixture、453/33/2 语法检查。另独立运行 6 个已检查的离线脚本测试：required CI、release version、opt-in XCTest log、nightly retarget、build metadata、DMG path guard，均 exit 0；Git/GH/build 命令由其 fixture mock，未触碰真实 tag、commit 或 release。[offline-checks-result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/offline-checks-result.json)、[large-payload-result.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/large-payload-result.json)。

**早期 finding 与发布流程结论**

指定 generation 3 Astra raw 目录、Luna G4 E2E raw 目录共核验 133 个文件、7,071,150 bytes（不含编译 module cache），并核对 8 份早期 Astra 报告，见 [prior-evidence-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/prior-evidence-audit.json)。只读取前代证据，没有运行旧 App 或使用前代 control 文件指挥当前审计。

| 历史问题 | G4 处理 |
|---|---|
| plist 版本传递、非阻塞分片读、stale thumbnail waiter | 版本实物重新核验、分片实际 E2E 重新执行；thumbnail 实际 loader Flight/取消链重审，现有回归日志通过 |
| genuine schema 008 backup、owned paste generation/slow AX fence、deferred replay owner lifetime | 当前完整生产链重审，保留此前指定缺陷的关闭结论；没有声称本轮跑过 native paste 或断电恢复。新的 schema 011 P2 另行报告，不能被旧 008 closure 覆盖 |
| spilled payload proof | 本轮额外完成实际 App 跨进程重开、直接解密与前后 SHA-256；20 MiB Core 补充边界 |
| promised-item 累积、UTF-16 decoder/caret、queued stale callback、details item identity | 读到当前 production 调用者/取消路径及测试断言，未发现指定旧缺陷重新出现；真实 UI/AX 运行仍未覆盖 |
| staging 删除边界 | 当前脚本路径规范化/containment 重审；独立离线 path-guard 测试通过 |
| soak extension 消费、preview timeout | runner 与测试边界重审，保留此前指定修复；没有实际 preview 循环或 24h/72h soak 通过证据 |

release workflow 使用 exact commit SHA 的 required CI、workflow 身份/最新 attempt 校验以及串行、不取消在途的 release concurrency；nightly main 分支和移动 tag 的显式 lease 条件已审查。打包路径 guard 和版本 override 元数据有离线/既有实物证据。仍有边界：上传多资产不是原子事务；可选未签名构建不等于签名、公证、Gatekeeper 下载首启已通过；冻结工作树内容多于 base commit，当前 HEAD 的远程 CI 状态不能代表这些尚未提交的源文件。未做任何远程调用来创建/更新发布物。

**最终验收边界与交接**

本轮没有确认需要按 P0/P1 规则提前停止的产品故障，因此完成了授权范围内的完整审查和 E2E。两项 P2 与一项 P3 已给出可重复 harness、原始输出、受影响调用路径和建议回归，不直接修改任何产品、测试或构建脚本。不能仅凭 gate manifest、socket 修复或 Core 性能样本宣布 release ready。

后续验收仍缺 **macOS 14、x86_64 运行、GUI/真实接收应用、权限与生命周期 UI、App Runtime 100k mixed history/UI 延迟、24h/72h soak、full Package TSan 的有效全通过结果**。这些是未跑/未通过状态，不是新增虚构缺陷。没有访问 `NSPasteboard.general`、已安装 PID 50253、正常用户数据根或 TCC 权限，也没有可见 GUI、TextEdit/Safari/Terminal/Finder 交互。

所有测试使用独立 mkdtemp 0700 根和一次性 32-byte/0600 密钥。8 个临时根及其密钥均删除，相关自有进程已退出；仅保留 synthetic 数据/密文、字节哈希和 reviewer harness，未保留密钥材料。[cleanup-final-audit.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/cleanup-final-audit.json) 与 [evidence-crosscheck.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-4/astra-review/evidence-crosscheck.json) 给出最终复核。本轮未 commit、push、tag、PR、publish 或 release。

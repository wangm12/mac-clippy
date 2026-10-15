**发布结论：阻断（RELEASE BLOCKED）。未解除 P0：0；P1：2；另有 P2：1。**

冻结 generation 2 尚不能发布或获得完整验收。独立发现 **ASR-G2-P1-001：实际 shipping Release 的版本元数据使新 CI/打包校验失败**；并核验并行执行者的 **E2E-G2-P1-001：有效长文本请求在控制传输阶段失败**，以独立 Darwin socket 探针进一步确认源码机制。两者是不同阻断，不重复编号。另确认 **ASR-G2-P2-001：旧缩略图 waiter 可取消重开后的新请求**。

此前 ASR-P1-001～005、ASR-P2-001～006 的指定源码缺陷均有可核对的修复；各项的测试强度、残留覆盖缺口及真实系统边界见下表。源码关闭不等于外部应用送达、长期稳定性或发布接受。完整 Package TSan 仍为 FAIL；过滤后的通过不能替代它。macOS 14 为 NOT RUN；锁定桌面下的可见 UI、TextEdit/Safari/Terminal/Finder、真实权限变化、sleep/wake 均为 NOT RUN/BLOCKED；没有运行 soak。

**身份、清单与审查方法**

审阅者：gpt-6-astra，独立 generation-2 source review。工作目录：/Users/mingjie/Documents/github/personal-projects/mac-clippy。开始时间为 2026-09-26 05:58 UTC（2026-09-25 PDT）。读取的控制文件为 /tmp/macclippy-phase6-control.json，revision 47，要求的五个字段均满足：

| 项目 | 实际核验 |
|---|---|
| generation / phase | 2 / generation-2-source-frozen-astra-review-and-e2e |
| mutation_in_progress / source_fix_pending | false / false |
| branch / HEAD / base | codex/core-reliability-hardening；HEAD 与 base 均为 79e987a982f15f9193392c9af98b66465efd5ee2 |
| 权威 manifest | /tmp/macclippy-phase6-source-manifest-generation2-root-freeze.json |
| sourceContentSHA256 | **b41b7cdbed5b5eb81bfc3997460277be600ac4c6f467f30f742959bf6602c823** |
| build-input files | **515** |
| manifest 文件本身 SHA256 | 99fee17015f61bf6c64139aadc1d04c70f9491adecf412e97f6afecdccb2b8f0 |

独立从 git tracked + untracked 候选重新枚举，按 suffix/exclusion 规则选出文件，逐个重读原始 bytes，计算 path、sha256、sizeBytes，并对路径排序、键排序、无额外空白的 UTF-8 JSON entries 数组计算 SHA256；没有通过导入 runner 来代替独立重算。开始、审查中及完成时核验均与冻结内容一致。515 项包括资源、配置及辅助构建输入，不代表 515 个 Swift 文件，更不是完整的 changed-file inventory。

本报告用 **E** 表示 build/hardening-phase6-20260925/generation-2/astra-review/，用 **G** 表示其上一级 generation-2/。完整证据位于 [审查证据目录](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-review)。初始身份为 E/identity-start.json、E/independent-manifest-start.json、E/frozen-manifest.json；终态为 E/identity-final.json、E/independent-manifest-final.json。

初始完整盘点为 **110 个 tracked changed + 151 个 untracked = 261 个路径**。其中 248 个属于 build manifest 的变更输入，正好对应 control 的 worktreeChangedPaths=248；另外 13 个不属于该 manifest。审查期间增加并行 generation-2 E2E 报告及本报告，最终为 **110 + 153 = 263**，产品输入仍为同一 515 项。untracked 中 **147 项是非审查证据文件**：140 项构建输入、5 项用户/工程文档、2 项 Python 缓存；另 6 项是 Astra 审查报告。完整逐路径列表在文末，不以清单摘要替代盘点。

| manifest 顶层 | 文件数 |
|---|---:|
| .agents | 5 |
| .github | 2 |
| .gitignore / .swiftlint-baseline.yml | 1 / 1 |
| MacClippy.xcodeproj | 5 |
| MacClippy | 161 |
| MacClippyKit | 252 |
| MacClippyTests / MacClippyUITests | 52 / 1 |
| Makefile / project.yml / scripts | 1 / 1 / 33 |

已读取四份早期 Astra 报告、/tmp/macclippy-phase6-luna-final-gates-result.md、docs/hardening-progress.md、docs/e2e-phase5.md 及最终原始日志作背景；发现、处置与数量以本次最终源码和证据复核为准。README、README-CN、release-process、restore-process-tests、competitive-comparison 也纳入清单/变更内容审阅。文档中的旧 SHA hidden smoke、原始 JSONL 已丢失的 30 秒 runner smoke、generation-1 PASS 均未迁移成 generation-2 验收。

**发现，按严重度排序**

**ASR-G2-P1-001 — shipping 元数据未接入版本设置，实际 Release 被新 gate 拒绝**

- 状态：OPEN；源码确认 + 对冻结 Release 产物独立执行校验得到 FAIL。
- 位置：[MacClippy/Info.plist:17](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/Info.plist:17)、[E2E-Info.plist:17](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/E2E-Info.plist:17)、[project.yml:14](/Users/mingjie/Documents/github/personal-projects/mac-clippy/project.yml:14)、[verify-build-metadata.sh:36](/Users/mingjie/Documents/github/personal-projects/mac-clippy/scripts/verify-build-metadata.sh:36)、[ci.yml:157](/Users/mingjie/Documents/github/personal-projects/mac-clippy/.github/workflows/ci.yml:157)。
- 触发：CI 构建 shipping Release 后运行 metadata gate，或 stable/nightly 经 Makefile/package-dmg/archive-signed 传入发布版本并校验产物。
- 机制：显式 Info.plist 将 CFBundleShortVersionString 写死为 **1.0**，CFBundleVersion 写死为 **1**。MARKETING_VERSION/CURRENT_PROJECT_VERSION 虽存在且发布命令会传入，但 plist 没有引用它们。新 validator 要求三段 X.Y.Z，并在发布时比较期望值。这里不是声称 macOS 不允许 1.0，而是该实际产物不满足仓库自己的新 gate，且发布参数不能改变它。
- 独立实证：shipping binary SHA 与冻结记录一致；对 G/ReleaseShippingFinalDerivedData/Build/Products/Release/MacClippy.app 执行 bash scripts/verify-build-metadata.sh，清除 EXPECTED_* 环境覆盖以匹配普通 CI 校验，**exit 1**，stderr 为 **error: invalid CFBundleShortVersionString: 1.0**。三份 Release 的实际 plist 都是 1.0 / 1。证据：[E/release-metadata-failure.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-review/release-metadata-failure.json)、E/artifact-independent-audit.json。
- 影响：现有构建成功记录不能证明 CI/release 可通过；shipping metadata 阶段及正式打包前校验被阻断。stable/nightly 的版本及 build-number 完整性尚未实现。
- 最小修正建议：在 XcodeGen 权威配置中把显式 plist 版本接到 $(MARKETING_VERSION) 与 $(CURRENT_PROJECT_VERSION)，再生成工程；对真实 shipping Release 以及 stable/nightly override 的实际 bundle 验证版本。不要放宽 validator 来掩盖固定版本。verify-build-metadata-test.sh 目前仅手工写入 1.2.3/42 的假 bundle，能测试校验器，不能测试 Xcode→plist 传播。本审阅者没有修改这些文件。

**E2E-G2-P1-001 — 非阻塞 accepted socket 把暂时无数据当成坏请求，长文本验收失败**

- 状态：OPEN；并行 Astra E2E 的实际失败已逐项核对；本 source review 另作独立 OS 机制探针。沿用 E2E lane ID，计一项 P1。
- 位置：[MacClippyE2EControlServer.swift:247](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:247)、[:323](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:323)、[:361](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlServer.swift:361)，以及 [driver:540](/Users/mingjie/Documents/github/personal-projects/mac-clippy/scripts/e2e/macclippy-phase5.py:540)。
- 触发：合法 JSON 请求分段到达，服务端读完已有片段而换行/后续 bytes 尚未到达。65,536 字节文本低于 fixture 的 1 MiB 和控制请求的 2 MiB 上限。
- 机制：listener 设置 O_NONBLOCK；accept 后未清除 client flags；receiveRequest 遇到任意 recv <= 0 立即返回 nil，外层发 invalid-request 并关闭连接，没有处理 EAGAIN/EWOULDBLOCK/EINTR。
- 实际失败：最终 E2E binary 2fe98570d49e36227f428ed990891a1aa23aeb68d0f1cd0ad37b3104e7b50595 的独占 PID 31397 已完成 9 个较小合成 capture，第 10 个请求在原 driver sendall 发生 BrokenPipeError errno 32。raw 输入、JSONL 第 14 行、stderr、ping 的 source/bundle/PID 身份均已独立检查并记录 SHA：E/e2e-failure-raw-audit.json；原件在 G/astra-e2e/runtime-smoke.*。不是 source reviewer 再启动了一次 App。
- 独立机制证明：[E/control-fragment-probe.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-review/control-fragment-probe.json) 使用本机 Darwin AF_UNIX、libc.accept 及同样的 flags：listener/accepted flags 都为 6，accepted 确实非阻塞；首读 29 bytes，下一读 errno 35/EAGAIN；按源码分支关闭后，剩余 65,536 bytes 发送 errno 32/Broken pipe。socket 仅建在本 reviewer scratch，未连接产品控制 socket、未使用 clipboard/UI。该探针确认实现存在此故障机制；它没有取得原来那一次失败的服务端 errno，故不把该历史 syscall 的内部状态冒充已采样事实。
- 影响：E2E transport 不可靠，阻断 spilled capture/restart 与 corpus 验收；不据此声称生产存储损坏或 shipping clipboard capture 丢失。旧 ASR-P1-003 的 spilled proof 读取修复不能解除本项独立 transport 阻断。
- 最小修正建议：对 accepted descriptor 明确选择有界阻塞 I/O，或用带 deadline 的 readiness/retry 处理 EAGAIN/EINTR，保持 framing/size limit；发送侧 :378–394 同样需要处理短写及暂不可写，避免在 MainActor 上等待背压。补 fragment request、65,536-byte request、分段 response/背压和超时的真实 socket 回归；不得靠缩小 fixture 通过。

**ASR-G2-P2-001 — 旧 card-thumbnail waiter 释放会取消新 session 的同 key flight**

- 状态：OPEN；源码确认 + scratch 有界逻辑复现。该 loader 在 base 已存在，属于本轮要求检查的最终 async-preview/cache 调用链，不归因于本次新增代码。
- 位置：[MacClippyCardThumbnailLoader.swift:126](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyCardThumbnailLoader.swift:126)、[:231](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyCardThumbnailLoader.swift:231)；实际调用为 DockModel.endSession→resetSessionThumbnailCaches（Selection.swift:358、376）及 CardImageThumbnail.swift:65 的可取消 task。
- 交错：旧 waiter A 等待 key K → endSession 清掉旧 flight 并恢复旧 continuation → 重开/新卡请求为 K 建立 waiter B → A 的迟到取消调用 releaseWaiter(K, A.id)。实现按 key 取得 B 的 flight，删除不存在的 A.id 后仍调用 accounting.releaseWaiter；B 唯一的计数 1→0，于是 B 的 operation 被取消。
- 影响：有效的新缩略图请求被旧 session 取消，卡片可能保留占位图；不涉及原始剪贴板数据删除。与已修复的 FileThumbnailScheduler 的 flightID fence 不同。
- 实证：[E/thumbnail-stale-waiter-evidence.json](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/hardening-phase6-20260925/generation-2/astra-review/thumbnail-stale-waiter-evidence.json)。保留生产 loader 与 waiter-accounting 方法体，仅去掉模块 import 并提供未触发的 RecordID/cache/downsampler stand-ins；OperationQueue 暂停。old release 前 new callbacks=0，之后=1 且返回 nil，probe exit 0。这是逻辑复现，非完整 App/可见 UI 测试；首次 scratch 编译缺 SDK 的失败和补 SDK 后结果均保留。
- 最小修正建议：release closure 绑定原 flight 身份，或在当前 flight 找不到该 waiterID 时立即返回；只对实际移除的 waiter 递减计数。增加 reset→同 key 新 load→旧 waiter release 的回归。现有 card-loader tests 测了 reset/缓存清理及取消后新请求，但未测试这个交错。

**此前 ASR 的逐项处置**

下表的“关闭”仅关闭该 ID 原先描述的源码缺陷；动态证据为本代原始日志核验，除另有说明，不是本 source worker 重跑 XCTest。P=MacClippyKit/Sources/MacClippyPlatform，C=MacClippyKit/Sources/MacClippyCore，A=MacClippy；测试路径分别为对应 Package Tests 与 MacClippyTests。

| ID / 原始问题 | 最终源码处置及生产链 | 本代回归与边界 |
|---|---|---|
| ASR-P1-001：真实 schema008 备份缺 representation_refs_auth，正确 key 也无法验证/恢复 | **指定缺陷关闭**。C/MacClippyBackup+KeyValidation.swift 检查列存在性，旧列取 NULL、旧 item 取 index 0；仅 raw legacy 允许无 roster，wrapped body 不降级。validate→staging migrate→install→Runtime reopen→finalize 全链复核 | HistoricalSchemaTests 的实际旧 clipboard001–008、独立旧 search001–004 与 base 对照一致；当前 kind=clipboardItem；populated live root、wrong/missing key 全文件不变、真实安装、元数据列表、text/image body、有效 PNG、inline 精确 bytes、spilled bytes、search 迁移并再次 reopen 后查询均有断言。focused 1/1；不是仅改 manifest.version。旧 itemIndex=0 的单独断言及更广旧 roster fixture仍缺 |
| ASR-P1-002：提交/取消未绑定 own-write clipboard generation；复审发现最终慢 AX 越过最后检查 | **指定缺陷关闭**。P/PasteInjector+Injection.swift:86、133、163、180、228 使用本次成功写入 count；fresh context 在最后 count 检查前；SnippetExpander+Expansion.swift:76、90 的 destructive admission 只读 cached identity + request/input/lifecycle，未在最后 count 检查后再次做慢 AX | GenerationOwnership 3、Gate 6、Restore 9 及 context tests 本代通过。新 copy/取消/权限变化不覆盖外部 bytes；prepare 未准入 completion=0，accepted post 关 gate 后 completion=1/Did=0。最终 AX 回归的成功路径敏感度缺口见后表；不承诺 OS 原子性或目标消费 |
| ASR-P1-003：默认 corpus 第五条 65,536-byte text 因 spilled 被 E2E 拒绝 | **原 payload-proof 缺陷关闭，E2E 验收仍阻断**。A/E2EControlVerification.swift 在 root lease 内从 authenticated snapshot 解析 present/spilled，至 1 MiB；不可用/超限 hash 为 null；driver 按稳定 ID/完整 representation proof 校验 | 读取实际实现及 Python regressions。最终 E2E 小样本 9 capture 成功；65,536 请求被新 E2E-G2-P1-001 transport 阻断，未到达成功 proof，restart 未运行。不能把原逻辑修复写成该端到端 gate PASS |
| ASR-P1-004：consume_extend_request 空实现，延长逻辑不可达 | **指定缺陷关闭**。driver:2212 起实际消费请求，绑定 root/run/UID/worker PID/请求 UUID、文件模式，receipt/lock 防重放，累计上限 72h；主循环执行 control-request 处理 | 37 offline tests 中含真实独立 Python worker、加速时钟、24→72 上限、重复/并发/错身份/不安全文件及 stop 的断言；不是只调用孤立函数。未运行真实 24h/72h soak |
| ASR-P1-005：weak deferred replay 丢最后 owner，native unretained event tap 无清理责任 | **指定缺陷关闭**。三个安排 replay drain 的 closure 强持有 self 至 drain；Lifecycle.stop 推进 generation/关 gate，但 active commit/replay 延迟清 tap；drain 后 main cleanup，deinit 可完成兜底清理。另沿 Runtime.stop/closeStorageForRestore、AppDelegate.installValidatedBackup/startRestoredRuntime 追踪所有者 | SnippetDeferredLifetimeTests 确实排队并阻塞 replay，stop 返回后放掉最后外部 owner，验证 FIFO/PID、weak owner 最后变 nil、实际 CFMachPort invalidation 与 run-loop-source 移除；本代 focused/full PASS。fixture 资源是实际 CF port/source，入口仍是 startForTesting，不能当作真实 CGEvent tap/AX teardown 完整系统证明 |
| ASR-P2-001：跨 poll 回退初始 snapshot，后恢复 B 时丢 A | **指定缺陷关闭**。P/MacClippyPasteboardReadRetryState:127 保存最新累计 change；Reading 合并按 (itemIndex, UTI)，绑定 changeCount/source/truncation/ordered types；新 generation 清旧 pending | SystemPasteboardRetryTests 使用真实 named NSPasteboard、两个相同 UTI promised items，分两轮 materialize 原 item，检查同 generation、累计中间状态、顺序、不同 bytes、单次 delivery/provider callback；自动 polling 在此 fixture 已关闭，原 timer 竞争缺口修复。本代 1/1 |
| ASR-P2-002：快速前文造成旧 caret；复审发现生产 decoder 丢 surrogate pair 和事件内 prefix | **指定缺陷关闭**。P/SnippetExpander+Input 的合法 UTF16 pair 解码及每 Character prefix offset 保留；FocusContext 预测 UTF16 caret，fresh selection 必须相等 | ContextTests:307 用真实 synthetic CGEvent.keyboardSetUnicodeString→handle，A/CJK/emoji/trigger 同事件，断言 7 Delete+Paste、PID/caret；:328 有 orphan-high 输入。13 项通过。不是只有 String-only helper；combining/low-surrogate/64-unit 边界仍有缺口 |
| ASR-P2-003：旧 queue progress/finish 越过 main hop 污染新会话 | **指定缺陷关闭**。A/DockModel+QueuePaste.swift、+Utilities.swift 的 progress、结果、finish 都核对 session、operation 和 cancellation token；旧 finish 不清新 token/队列 | QueuePasteLifecycleTests 实际 DockModel+Runtime，gate 控制异步时序、延迟 main publication，检查旧进度/完成不改新 session；CancellationIntegrationTests 经生产 queue staging 取消，无 event/频次变更。只是假 poster，不是外部按队列插入 |
| ASR-P2-004：1,000 preview 固定 120s socket timeout 小于动画总预算 | **指定缺陷关闭**。driver preview budget 随 cycles 增长，1,000 默认预算约 695s，且精确核对完成数量；服务端逐次等待 ready/hidden | offline budget/断言回归通过；实际可见 1,000 cycles 为 0/1,000，BLOCKED。有限客户端预算不保证任意系统负载下每轮 30s 上界的总和都成功 |
| ASR-P2-005：详情 row id 只有 UTI，丢 native item 身份 | **指定缺陷关闭**。A/RuntimeModels.swift 的 representation ID 包含 itemIndex+UTI；Runtime.details 保留 index；Details+Sections 展示 Item 序号 | LabelTests.testDetailsDistinguishRepeatedUTIAcrossPresentAndSpilledItems 实际写入同 UTI 的 present/spilled 两 items，经 Runtime.details 检查不同 ID、index、state、availability、stored byte sizes；App full 中通过 |
| ASR-P2-006：非默认 staging canonicalization 把 .build 根误作子目录而允许删除 | **指定缺陷关闭**。scripts/package-dmg.sh 逐组件 canonicalize 已有/未有路径及 symlink，使用实际 canonical 值，先拒绝根/越界再删建 | 8 个 copied-script/stubbed-tool 场景的 raw log 与脚本哈希已核验：根、规范化根、未存在路径、symlink escape、合法 child、外部 sentinel 保持。没有实际打 DMG，且真实版本 gate 另有新 P1 |

**生产链、锁与生命周期的独立审查**

| 范围 | 最终调用链和判断 | 生产/测试边界 |
|---|---|---|
| capture / promised reads | SystemPasteboardReader→observer poll/retry→capture mapper→Runtime admission/capture queue→store+search。每次 native read 前后及提交前检查 generation/cancel；原生 nil、有效零字节、unavailable、oversized 分开；sentinel 是本进程精确 count 消费，不泛化成保护别的已安装进程 | 原生 provider 回归确实走 AppKit named board；同进程 provider 兑现不代表任意外部 provider 行为 |
| 输入预算及过载 | 初读最多 32 items、每 item 64 UTIs、UTI 256 bytes、单 representation 128 MiB、总 change 256 MiB；3 次版本尝试共享 0.2s/16 次 retry，observer 默认共 4 次观察尝试。capture admission 8 jobs/256 MiB 估算预算（payload 放大与 metadata 计入），释放跟随实际 payload 使用结束；过载记录明确 drop/error，容量释放只尝试恢复最新可用 generation | 不能恢复已经被后续系统 copy 覆盖的所有中间内容。同步 provider 已进入后不能被硬中断，0.2s 是发起后续读取的软预算，不是内存分配或停机硬上限 |
| OCR / stop / close | OCR 8 jobs/64 MiB；停止后正在执行的 recognizer 仍占 byte reservation，实际返回后才释放。Runtime.stop 关 admission、cancel token、使 lifecycle 失效；已准入 commit 可完成，旧 UI 发布被 token 拒绝。restore background drain capture/maintenance/OCR/commit、退役 thumbnail cache、关闭 read leases/DB，之后替换 root | OCR recognizer 测试是假 async recognizer，但真实 Runtime 调度和预算。40MiB blocked old OCR→restart 拒绝额外32MiB→旧任务退出后新任务可执行的断言有效。普通 stop 非阻塞不等于 restore 的安全 barrier 可以无等待完成 |
| 锁序与 main | Runtime store/lifecycle/commit admission 锁、maintenance coordinator、DB read lease、blob registry 逐层追踪；重活目录遍历、blob I/O、压缩解码、backup 文件复制移到短 snapshot/fence 之外。AppDelegate 的 restore drain 在后台，未发现 main 同步等待正需 main.sync 的 expander worker 的闭环 | main 仍承担 AppKit、fresh AX/NSWorkspace、tap install/teardown、panel rendering。原生 AX/文件服务可能阻塞；测试没有给出主线程 hard latency 保证。search repair malformed 扫描风险另列 |
| snippet 自动展开 | Runtime→SnippetExpander lifecycle→native callback→input request/version/focus/caret→fresh context→injector own write→fresh context→最终 owned count→短 admission/准备 Delete→Delete+Paste→request completion→定向 FIFO replay→tap teardown | PID 不是 AX element 锁；已接受 Delete 后完成 Paste 是避免只删不贴的责任，不是撤销已经发出的事件。物理焦点变化、退出、真实投递结果未验证。三个 strong replay owners 消除了早期弱引用空窗；真实 Runtime 及 restore callers 已复核 |
| paste 结果与队列 | Runtime paste/ordered/queue/transformed→typed injected / preparedForManualPaste / failed / cancelled→DockModel 反馈。history 无权限可保留选中内容供手动粘贴；snippet 不走假手动成功，旧 clipboard 保留。queue manual stop 包含当前和剩余 IDs，cancel 不伪装 completed；频次只记 accepted injection | 两种 poster 路径均在 tests 被替换。injected/afterPasteEvents 是投递接受/返回语义；队列最后 clipboard 内容或 callback 次数不能证明每项外部送达 |
| attachments / 安全删除 | schema009–012 的 verified reference index、authenticated roster、body envelope→backfill→retention/manual delete/journal→blob read lease→最终 ref recheck。recordID/itemIndex/order/UTI/state/blobID/ciphertext digest 绑定；只信 marker 0/1；篡改/错 key 不被降级 legacy。distinct blob keyset 分页跨 256，不能以 journal record-offset 漏共享附件 | 不完整 legacy spilled metadata 不能被认证为真：retention 可移除逻辑记录但全局抑制不安全 physical deletion；strict manual edit/delete/backfill 可 fail closed。此保守行为可能影响操作可用性/磁盘回收，不能宣传所有 legacy attachment 都已可安全删除 |
| backup / restore | Runtime snapshot lease→在线 DB snapshots→blobs/manifest→outer paths/size/SHA + inner decrypt/roster/schema-health 校验→预检 key→stage copy/migrate→restore journal/old components→install→新 Runtime open/start→finalize；失败走 previous generation recovery | staged/install 不是一次跨多目录的原子 rename；通过持久 journal 和关闭读写者实现进程崩溃恢复。缺 key 可只读报告 keyCompatible=false，但不允许 install。没有用 hash-only 检查代替内层认证，也没有在备份源上迁移 |
| search / migration | 旧 search001–004 保持兼容；maintenance indexes/repair pages 与源 metadata revision、repair epoch、当前 pending IDs 联动。修复每页在 store fence 内读取最新内容并提交，页间放锁，后发生的 projection failure 不被旧完成状态清除 | RuntimeSearchRepair 真正驱动页间 named-board capture 和 Runtime.history，另有 edit/delete fence、restore cancellation、byte split 更新验证；scale 主体依然是直接 seed 的纯文本库 |
| representations / replay | capture hash 单 item 保持旧规则，多 item 纳入 itemIndex；migration012 使用 record/item/UTI identity；legacy 解码 index 默认0；Runtime playback 按 native item 分组，rich replay 保留可用 formats，plain 明确派生 primary 文本；edit 仅失效 primary item 的旧格式，保留其他 item | App 的 production capture→close/recreate Runtime→search→normal/plain copy 回归检查稳定 record ID、多 item/repeated UTI/CJK/emoji；不是外部进程重启/OS recipient。images/files 的 replay 仍为原生表示，不把 sourceFormat 与 observed primaryContentKind 混同 |
| preview / caches | Dock preview/loading 通过 session/op/identity/cancel fence；FileThumbnailService 限 worker=2、pending=64、cache=48/32MiB，取消正在 decode 的工作保留 worker slot，late finish 不回填新 session。disk cache retire 拒新 I/O并等已准入 I/O，避免旧实例破坏 restored root | disk-cache retirement 与 file thumbnail tests 能证明相应生产组件。另一个 CardThumbnailLoader 有本报告新 P2；不能把 FileThumbnailService PASS 外推给它 |
| app target / E2E | Generated pbxproj：shipping 132 Swift sources、E2E 143、App tests 52、UI tests1；shipping 无 MACCLIPPY_E2E，control/recipient/file-keychain/isolation helper 只在 E2E target。E2E 0700 owned marked temp root、0600 socket/key、flock、named board、run-specific defaults、严格 retention env；Shipping 10k 与 stress 200k 独立 | 本次静态核对和 arm64 nm→swift-demangle 未见 shipping E2E control/recipient/isolation 或 appendTestRecord symbols；见下方仍链接的 package test seams。可见 E2E paste/search/preview 会激活面板，所以锁屏时不可运行 |
| scripts / CI / release | CI App 常规/TSan 只选 MacClippyTests；scale 两个 env flag 且要求 suite 真执行零 skip。required-ci 校验 workflow ID/path、精确 head SHA、完整分页、最新 attempt，不以旧 success 绕新 fail。nightly main-only、固定 concurrency group、精确 SHA/force-with-lease，仅移动 nightly | shell 回归主要 mock git/gh/构建工具；未运行远端 CI、签名、公证、tag/push/release。允许较早 main 事件 rerun retarget 不是本项目已定义的“必须最新 main”违约。实际版本传播失败见 P1，不能从这些脚本局部测试推出可发布 |

**以前报告的测试缺口，逐项复核**

| 旧缺口 / 风险 | generation-2 处置 |
|---|---|
| 历史 fixture 仅改 manifest、kind 错、空 search、无 image/spill/inline equality、只 body 解码、live-root 未完整比较 | 核心缺口已补。与 base 的 clipboard001–008、独立 search001–004 对照记录在 E/historical-ddl-comparison.json、E/historical-search-ddl-comparison.json。fixture 使用真实 legacy encrypted body，valid PNG 与 spill；wrong/missing key 比较整个 populated live/backup 常规文件 bytes；成功后 fresh metadata/list/playback、inline/blob bytes、search migrate/reopen/query。没有额外独立 metas API 断言；itemIndex=0 与真实历史 v1/v2 roster 全矩阵仍未单独证明。pinboard/snippet 历史组合也未覆盖 |
| 重新 hash 外层 manifest 后内层认证是否仍 fail closed | 三个实际 negative fixtures 覆盖 missing roster、corrupt roster、unsupported wrapped envelope version，重算 DB bytes/hash 后执行 validate/install；本代 Compatibility6通过。仍缺 backup-level swapped/replayed roster 全组合，且这三类的 live sentinel 不是四库+blob 的完整 populated negative fixture；不能借正确 key 旧库 fixture 外推 |
| 最后 owner / unretained native tap / Runtime restore callers | strong replay closure、CF资源回收 fixture 与实际 App stop/restore 链已补核；原 P1关闭。无显式 stop 直接丢 owner、取消 suppressed Tab 同时最后 owner 释放、真正 CGEvent tap+AX notification teardown 的完整组合仍未实跑 |
| afterPasteEvents 恰好一次、两个并发 requests、false-beforePaste、事件准备失败、stale/duplicate completion | 生产互斥分支与 request.identifier guard 已检查；3 个 gate 场景有0/1直接断言，Delete 开始后 stop 的匹配 Paste/FIFO 有断言。正常成功的完整 callback 时序、两并发请求隔离以及全部拒绝分支直接计数仍缺；不是已确认第二个 completion 缺陷 |
| 最终 slow AX 边界的回归敏感度 | 当前回归把外部新 copy 放在 owned write 后的 fresh-context 阶段，并检查后续 context reads 为0/无 destructive events。但该变更令预检提前失败，仍不能单独阻止成功路径重新加入第5次慢 AX。当前源码最后 boundary 的顺序正确；建议另测成功路径阶段顺序，不据覆盖偏好新增 P1 |
| Unicode 的真实 decoder | 已有真实 CGEvent mixed ASCII/CJK/emoji+trigger 和 orphan-high；不再只测 String helper。combining prefix、orphan-low、high/high/low、64 UTF16 unit 边界、跨事件 emoji 后 trigger 仍缺；真实控件如何处理畸形输入亦未验证 |
| 同 UTI 两 promised items 分轮到达；fixture 自动 timer | 真实 AppKit provider 回归已补，显式关闭自动 polling，检查累计中间状态和最终双 payload。部分恢复后再 churn/cancel/耗尽累计预算的交叉组合仍未完整覆盖；其他独立 reader/budget tests 不能冒充组合测试 |
| queue shutdown、cancel、生命周期后保留的 byte budget | capture backpressure、stop/restart blocked commit、OCR retained reservation、Runtime close-storage、search repair restore drain、DB read lease close 均有生产组件回归。等待 native provider/AX/recognizer 返回仍无绝对时间保证；stop 与可安全替换 root 的 barrier 必须区分 |
| >256 删除 × 共享附件 × 不完整 legacy | 257记录/256不同blob journal 测试确实检查所有 distinct IDs；retention 另有513跨页、257候选更新、pin/shared保护。legacy safety 的少量记录证明保守不删、不信错 key。尚无把三维合并成一个真实 legacy 大分页共享 survivor 的端到端 fixture；源码 keyset/refcheck 已查，不因此捏造丢失缺陷 |
| 命名强于断言的测试 | RepresentationCaptureRollbackTests 的 sentinel 名称只做 store append；reconciliation 名称只读 ref IDs。部分 batch feedback tests 在测试内重算“完整成功”。不把它们计作实际 sentinel/reconciliation/模型反馈证明；分别依靠真正 observer/sentinel、reconciliation、PasteResultModel/QueueLifecycle 路径 |
| preview/root replacement 和 stale cache | blob read leases、disk-cache retire、file thumbnail 的 cancelled worker/late finish fences 有真实组件断言。CardThumbnailLoader 的旧 waiter/new-flight 交错现确认为新 P2；当前全量绿色没有覆盖它 |
| shipping test seams 是否全部移除 | final project+arm64 demangled symbols 已核验：E2E控制端点、DEBUG append/maintenance hooks未见；仍有 startForTesting（2个匹配符号）及 MacClippyThumbnailDiskCacheTestHooks（38个匹配符号）。后者生产 public initializer 传 nil，配置 hook 的 initializer 为模块内部；未发现 shipping UI/环境控制入口可配置它。**不能声称所有 test seams 均未链接**，也无证据把符号存在升级成可利用 P1 |
| malformed repair LIMIT 与 main stall | C/SearchStore+RepairPages.swift 的 LIMIT 限异常结果数量，不能限制所有 healthy rows/join/union 扫描；Runtime 调用在 store lock 内。100k fixture未测该扫描锁持有分布及并发可见卡顿，风险仍待量测，未确认实际延迟故障 |
| restore child death 的证据强度 | production install/recover/finalize，真实独立 xctest子进程、nonce/PID/checkpoint、SIGKILL验证，新进程恢复后打开四库+payload，完整 old/new generation检查；非TSan final suite中5个父测试通过、worker1跳过。原临时 workspace成功后被清理，aggregate log不是保留每次全部child原件；无断电/文件目录fsync durability证明 |
| soak active workload、身份及错误断言 | driver已加入 stable recordID/native payload proof、预期查询ID、capture/error counter增量检查；retention env通过 Swift launcher传递并由Runtime effective policy验证，offline worker/control协议有回归。负载主要是mixed capture/verify/search及delay，不是全image/files/OCR/delete/backup/reconcile操作矩阵；24h和72h实际均0小时 |
| 真实 recipient / 系统事件 / macOS14 | 仍未执行。synthetic recipient 记录 named-board原生item/UTI/bytes后所得insertionCount是内存接收器行为，不能证明TextEdit等实际插入。fake trust/DisplayGenerationPolicy不等于TCC变更、sleep/wake或lock/unlock；deployment target14.0不等于macOS14 runtime PASS |

**Gate 的原始证据审计**

E/gate-log-audit.json 保存日志 SHA/大小、终态行和 TSan 计数；E/gate-manifest-audit.json 展开 summary 指向的实际 manifest，并重算 entries，与冻结源比较。以下 final Swift6-fix 后的 Package/App/scale/focused、TSan、Release 前后 manifests 均为最终 515 项摘要。早期 package-focused/full 的 532-file manifest、summary-pre-e2e/pre-swift6 以及旧失败/修复前日志没有冒充最终通过证据。

本 reviewer 另外独立重跑 pinned SwiftLint **0.63.2**，full 使用既有 baseline，changed-file 使用 strict + 同 baseline，两者加 no-cache，避免写仓库外缓存；两个 exit 均0。随后对同范围 **446** 个 Swift 文件逐文件 swiftc -frontend -parse，全部 exit0。记录为 E/independent-static-gates.json、E/lint-full.log、E/lint-strict-changed.log、E/independent-parse.json。此处 strict 仍是带既有 baseline 的 gate，不是宣称整个库不存在历史 lint debt。

| gate / 最终 raw log（G下） | 结果 | 本次如何核验 / 范围 |
|---|---|---|
| pinned-lint-after-swift6-fix2.log | PASS：446 files，0 violations；changed221 | 原始尾部446/0与strict221记录；独立同版本no-cache full/strict再次exit0 |
| swiftc-parse-after-swift6-fix2.log | PASS（独立复跑确认446/0） | 原日志为空，单凭空日志不能证明退出码；以本次逐文件退出码补证 |
| package-focused-after-swift6-fix.log | **40 executed / 40 passed / 0 skipped / 0 failed** | 8类：context13、restore9、compatibility6、gate6、generation3、historical1、provider1、lifetime1；终态:502 |
| package-full-after-swift6-fix.log | **640 executed / 636 passed / 4 skipped / 0 failed** | :1603；不能把640称作640通过。skip为child worker、10k observer lifecycle、100k scale、20MiB scale |
| app-unit-after-swift6-fix.log | **419 executed / 417 passed / 2 skipped / 0 failed** | :6956及TEST SUCCEEDED；skip为RuntimeScale和真实input-tap测试。仅MacClippyTests |
| package-scale-opt-in-after-swift6-fix.log | PASS：2/0 skipped/0 failed | 100k纯文本直接store/search fixture +20MiB spill/delete；套件38.820s不是查询p95 |
| app-runtime-scale-opt-in-after-swift6-fix.log | PASS：1/0 skipped/0 failed | 实际named RuntimeScale case通过、无skip；10k纯文本直接seed后Runtime.history，30s宽松单次断言，非100k混合GUI benchmark |
| release-shipping-final.log / release-e2e-final.log | BUILD PASS | 最终前后source manifests一致；独立核验binary SHA、bundle、双架构。但shipping metadata gate独立FAIL |
| release-swift6-final.log | BUILD PASS | 命令明确SWIFT_VERSION=6，Release；不是把Debug Swift6与普通Release拼成一次执行 |
| package-tsan.log | **FAIL：640 executed / 632 passed / 4 skipped / 4 failed tests；94 failures，含1 unexpected** | :2526；73条interceptor初始化ERROR。四个失败为afterFinalize、every install、rollback/cleanup、staged move child death。94是断言/异常总数，不是94个测试 |
| package-tsan-without-crash-child.log | PASS（过滤范围）：634 executed / 631 passed / 3 skipped / 0 failed | :1977；排除整个6项crash-child class，不能消除上行FAIL |
| app-tsan.log | PASS：419 executed / 417 passed / 2 skipped / 0 failed | :7012；独立于Package TSan。所查TSan日志没有data-race告警文本不等于完整race-free证明 |
| Python handoff raw + hashes | PASS：Python3.9.6，37 tests；package-path guard8检查 | 本 reviewer重算全部handoff scope文件和7项raw证据hash，均一致；unittest.log实际37/OK，guard逐项8PASS。详情E/python-handoff-independent-audit.json；没有以stub包装通过代替真实签名/DMG构建 |
| shipping verify-build-metadata | **FAIL，本 reviewer新执行** | 实际冻结artifact，exit1，版本1.0；见ASR-G2-P1-001 |
| generation-2 hidden E2E | **部分成功后FAIL** | 独立核验并行lane raw：9个有界合成capture成功，第10个长文本传输失败；不同lane实际执行，本source reviewer没有运行App。未获得reopen/search/replay验收 |
| 10,000 observer lifecycle opt-in stress | NOT RUN（最终源独立启用证据未见） | default suite确实skip；generation1 opt-in通过不转移 |
| 签名/公证、完整CI/release、真实外部应用、可见UI、macOS14、24h/72h soak | NOT RUN / BLOCKED | 三个Release均CODE_SIGNING_ALLOWED=NO。没有发布或远端执行；GUI锁定，无macOS14环境，无soak |

完整 Package TSan 的失败表现是 crash 子进程报告 sanitizer interceptors 初始化过晚，实际得到 SIGABRT/缺 start-checkpoint evidence；普通非 TSan crash 测试通过与过滤 TSan 通过都不能把这次失败改名为完整 TSan PASS。当前 required CI 的完整 Package TSan 步骤亦没有可据此宣称已绿的证据。

**实际 Release 身份**

独立直接读取 bundle Info.plist、sha256 和 lipo，结果见 E/artifact-independent-audit.json。没有启动任何一个 bundle。

| 产物 | bundle / configuration / architecture | executable SHA256 |
|---|---|---|
| ReleaseShippingFinalDerivedData/.../MacClippy.app | com.macallyouneed.macclippy / Release / x86_64 + arm64 | 1b608645e9f255b59a6bed7cf5ea2602fde42ece361f85decbf7ac345e71d5b4 |
| ReleaseE2EFinalDerivedData/.../MacClippyE2E.app | com.macallyouneed.macclippy.e2e / Release / x86_64 + arm64 | 2fe98570d49e36227f428ed990891a1aa23aeb68d0f1cd0ad37b3104e7b50595 |
| Swift6ReleaseFinalDerivedData/.../MacClippy.app | com.macallyouneed.macclippy / Swift6 Release / x86_64 + arm64 | fffc0a97399e10a8783846df959bdd45878da7e466dfbdd711bf710bd441745b |

E2E 内嵌 source SHA 等于冻结 SHA，最低系统声明为14.0；两个架构的存在不证明 Intel或macOS14实际运行成功。Shipping没有E2E专用内嵌来源字段，其来源绑定依靠实际构建前后manifest及二进制SHA。生成工程和symbols证据为 E/generated-project-audit.json、E/release-symbol-audit.json；已核对实际包含52个App测试源。

**限制与交回**

这是最终冻结源码、生产调用链、回归实现、原始 gate 和构建产物的独立审查，不是一次全系统运行验收。清单的每个文件均做字节/身份核验；按变更、风险和调用链读取实现/测试，不把515个文件的hash验证描述成逐行形式证明。编号阅读记录在 E/reads.jsonl；较大 diff 与其他直接读取也参与判断，日志的读取范围不是“每行均已形式验证”的声明。资料中的外部竞品说明没有重新上网验真，未用它们作发布结论。

本 source worker 没有重跑 Package/App XCTest，没有运行 App、可见 UI或系统权限操作；独立执行仅包括只读metadata verifier、静态lint/parse、隔离thumbnail逻辑和Darwin socket探针。并行E2E的9个capture/第10个失败严格归属于其自身记录。未接触受保护的安装版 PID 50253 或其数据，未读写NSPasteboard.general，未解锁桌面，未改变TCC、登录项、sleep/wake。没有启动或延长soak；旧30秒smoke和offline加速worker都不算soak。

未解除的发布阻断仍为 **P0=0、P1=2**：ASR-G2-P1-001 和 E2E-G2-P1-001；P2=1为ASR-G2-P2-001。没有因测试覆盖偏好将其他风险升为P1。只写本报告和指定scratch，未修改产品、测试、项目、CI、脚本或用户文档；未commit/push/tag/release。报告完成后结束本轮，交由root安排Luna修复及新冻结代次复审。

**完整变更路径附录**

以下是相对 base 的 tracked changes 与所有 non-ignored untracked 路径；审查证据报告单独标记，build/下被gitignore排除的证据不混入产品清单。该附录由最终git枚举生成，详情及逐文件SHA在E/inventory-final.json。


**Tracked changed（110）**

```text
.github/workflows/ci.yml
.github/workflows/release.yml
MacClippy.xcodeproj/project.pbxproj
MacClippy/MacClippyApp.swift
MacClippy/MacClippyAppDelegate+DisplayLifecycle.swift
MacClippy/MacClippyAppDelegate+Maintenance.swift
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

**Untracked 非审查证据（147）**

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

**Untracked 审查报告（6，仅作为证据盘点）**

```text
docs/review/astra-e2e-results-generation2.md
docs/review/astra-e2e-results.md
docs/review/astra-package-rereview.md
docs/review/astra-package-rereview2.md
docs/review/astra-source-review-generation2.md
docs/review/astra-source-review.md
```

终态独立重算时间：2026-09-26T06:36:39.879034+00:00；control revision 47；515项SHA仍为 b41b7cdbed5b5eb81bfc3997460277be600ac4c6f467f30f742959bf6602c823；差异0。

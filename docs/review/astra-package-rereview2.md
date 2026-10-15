**Phase6 Package 第二次独立静态复审 — v1.0**

审阅者：gpt-6-astra；日期：2026-09-25。范围：immutable snapshot2 的 injection / snippet / pasteboard read-retry / backup 及相关测试。**本轮发现 ASR-P1-005，状态为 `CONFIRMED_SOURCE`；snapshot2 不能据此获得 Package 或全局验收。** 四项原有 Package 问题的修复均可从源码确认，但仍有回归覆盖缺口，独立运行一律 `NOT RUN`。

本报告不覆盖当前可变 App、runner 集成或后续 Package 修改。Native 的 focused 30/0、Package 639/4 skip/0、App 419/2 skip/0 是控制文件转述的执行结果，本审阅者没有执行或独立复验这些结果，也没有把它们归为本轮动态通过。

**身份、权限与证据**

| 项目 | 精确身份 |
| --- | --- |
| snapshot2 | 249 个文件；`a3b303e96f28cb7ddb69bbc22c17fbc2c777d16afd974ccb499c1bc9b954fe50` |
| snapshot2 manifest 文件 SHA256 | `858a7391e4bb9273e23671fb72d6fa7042e3e8bdca5e482e8ca83a72b4f3666c` |
| 创建时间 | `2026-09-25T22:18:32.799547+00:00` |
| 实际源码读取根 | `/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/macclippy-phase6-package-review2-1h5diasy` |
| root 保存的同内容副本 | `build/hardening-phase6-20260925/remediation-evidence/package-snapshot-2` |
| snapshot1 对照 | 248 个文件；`e79634a6be8a71ab40918c92991627039fb111631c380838f153898fabdc7e8f` |
| 允许的历史 base | `79e987a982f15f9193392c9af98b66465efd5ee2`；仅用于 schema 和 App 所有权调用点的历史背景 |
| 本轮元数据根 | `/tmp/macclippy-phase6-package-rereview2-20260925T2222Z` |

内容摘要按 manifest 的 compact、sort_keys JSON entries 数组计算。审阅前后逐文件验证 snapshot1、snapshot2 的字节数和 SHA256，manifest 自身 SHA256 也不变；交付前另验证 durable snapshot2 的全部 249 个文件与 manifest 完全一致。[前验记录](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/hashes-before.json)、[后验记录](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/hashes-after.json)。全文路径及行号除明确标注历史 base 外，均映射到上述 snapshot2，不能套用到当前工作树。

每个实质批次前读取 control；初始 revision 37，交接时 revision 44。`package_review_snapshot2` 与 `package_review_instruction2` 明确授权本轮不可变复审，未把 `mutation_in_progress=true` 解释为全局冻结。已读第一份 Package 报告 v1.0、Astra source review、follow-up notes 和 pending_findings；没有覆盖第一份报告。全部写入限于本报告和专用 `/tmp` 证据；没有运行构建、测试、产品、进程、UI 命令，也没有提交、推送、tag 或 release。

**四项原有 Package 问题的处置**

| finding | snapshot2 源码结论 | 独立运行与验收限制 |
| --- | --- | --- |
| ASR-P1-002 | `RESOLVED_BY_SOURCE_INSPECTION_AWAITING_RUNTIME`：最终慢上下文检查移到精确 owned generation 检查之前；snippet `beforePaste` 已无 fresh AX 查询 | `NOT RUN`；新增真实 expander 回归会执行 owned write 后的第 4 次上下文 hook，但缺 completion 零次断言，也不能单独阻止重新引入第 5 次慢查询 |
| ASR-P2-002 | `RESOLVED_BY_SOURCE_INSPECTION_AWAITING_RUNTIME`：生产 CGEvent 解码处理有效 surrogate pair；同事件 prefix 的 UTF16 偏移进入 caret anchor | `NOT RUN`；已有真实 CGEvent 混合 ASCII/CJK/emoji 测试，combining、孤立 low surrogate 等边界尚缺 |
| ASR-P1-001 | `RESOLVED_BY_SOURCE_INSPECTION_AWAITING_RUNTIME`：旧 schema 只读 key 校验兼容；wrapped record 的 roster / envelope 认证未放宽 | `NOT RUN`；历史 fixture 已纠正并实际安装到 populated live root，但 restored search、inline byte equality、完整 live-root 不变性等证明仍不完整 |
| ASR-P2-001 | `RESOLVED_BY_SOURCE_INSPECTION_AWAITING_RUNTIME`：同 generation 累积重试保留恢复结果，按 `(itemIndex, UTI)` 定位 | `NOT RUN`；新 fixture 确实走 AppKit named board → production reader → observer；自动 timer 与手动 poll 并存造成确定性风险 |

这些状态说明原有已定位缺陷在当前快照中的源码修复，不等于各项验收矩阵已全部完成。没有把下文 coverage gap 自动升级为新的产品 P1/P2。

**新增 ASR-P1-005 — 延迟回放开始前释放最后持有者，会丢失 tap 清理责任**

严重度 P1；`CONFIRMED_SOURCE`；runtime `NOT RUN`。本轮已通过普通 commentary 立即报告，root 在 control revision 41 分配正式 ID，并交由 Native Luna/max 处理。本报告不实施修复。该问题位于本轮重新追踪的完整生命周期链，不声称由 snapshot1→2 的八文件差异新引入。

源码证据链：

1. `MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+Lifecycle.swift:69` 使用 `Unmanaged.passUnretained(self)`；第 70–73 行 callback 从裸指针取回 expander 并调用 `handle`。第 128–133 行把 source 加入 main run loop、启用 tap，再保存在实例属性中；native callback context 本身不拥有 expander。
2. `MacClippySnippetExpander+Expansion.swift:125–153` 完成一次 commit 后，清除 committing 标记，设定 `deferredInputReplayActive` / scheduled，然后在第 147–149 行用 `[weak self]` 入队。`MacClippySnippetExpander+DeferredInput.swift:34–36,100–102` 的键盘与取消 Tab 路径也使用弱捕获。
3. 若最后一个外部持有者在 `expand` 返回后、入队 drain 尚未获取强引用前释放，`MacClippySnippetExpander.swift:154–156` 的 `deinit` 会调用 `stop()`。`+Lifecycle.swift:156–165` 因 replayActive 为真而故意不移除 run-loop source、不禁用或 invalidate tap，等待回放完成后清理。
4. 实例释放后，排队的弱闭包不能再执行 drain；需要实例才能调用的 `finishDeferredStopIfNeeded`（`+Lifecycle.swift:177–204`）也失去执行者。已注册的 native source 和未持有对象的 callback context 没有可靠的寿命闭合。

后果是已吞下的缓冲键盘输入可能丢失，且仍注册的 tap callback 可能访问已释放实例，造成崩溃或内存安全问题。这里确认的是源码所有权缺陷与可构造的时序；没有观察到真实崩溃，也未证明当前可变 App 的具体释放时序。正在执行的 `expand` / drain 会持有方法接收者；问题窗口明确限定为排队后、drain 开始前。

确定性回归应先用 semaphore/barrier 占住 replay queue，通过真实 expander + injector、named board 和 fake posters 开始一次提交，在首个 Delete 阻塞时缓冲 keyDown/keyUp/flags，放行 Delete+Paste，确认 worker 已退出且 replay 已入队，再在主线程释放最后一个 expander 持有者，最后放行 replay queue。同时覆盖先 `stop()` 再释放、取消 Tab 入队路径。断言生命周期由明确所有者持有至安全结束，已吞事件按 captured PID 顺序完整回放，tap/source 在实例释放前恰好移除/失效，且 stop 不等待受阻 replay queue。

仅使用 `startForTesting()` 的 weak sentinel 回归不足以证明 native source 清理：`+Lifecycle.swift:210–227` 不创建 event tap。需要覆盖 production 生命周期所用的资源所有权接口，或使用隔离的 native resource fixture；不能只验证数组排空。可在不触碰 `.general`、不向系统投递真实键盘事件的情况下使用受控资源与 posters 完成确定性检查。

历史 base 的 App 背景：`MacClippy/MacClippyRuntime.swift:46` 强持有 snippetExpander，220–223 行初始化，228–234 行 Runtime deinit 调用 stop；`MacClippyRuntime+Lifecycle.swift:129–144` 的 stop 转交 expander.stop，241–253 行权限刷新也 start/stop。历史 `MacClippyAppDelegate+Maintenance.swift:201–235` 的恢复通过 `rollbackStartup()` 及异步 install/start 切换运行时。它们只用于定位最终复审入口，不能证明当前 App。control revision 42 另外转述 root 在可变 App 看到的 `MacClippyAppDelegate+BackupRestore` / oldRuntime 持有链；本轮没有读取或独立采纳为通过证据。最终冻结审阅必须核对 Runtime 强持有、stop/deinit、备份恢复 oldRuntime 异步释放、权限关闭和退出路径，以及 off-main deinit→main.sync 是否与调用方等待形成死锁。[历史读取身份](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/base-context.json)。

**ASR-P1-002：最终上下文、clipboard generation 与提交边界**

`MacClippySnippetExpander+Expansion.swift:31,44,57–62,81` 的 fresh context 检查贯穿计划与提交预检。`MacClippyPasteInjector+Injection.swift:168–175` 在成功写入并保存精确 owned changeCount 后检查 ownership、权限及 `validateCommitContext`；第 187–188 行进入短 admission 并再次检查同一个 owned generation。此后的 snippet `beforePaste` 只检查 gate、request/lifecycle/input generation、cached focus identity，并取得 commit 状态（`+Expansion.swift:90–119`），没有 fresh AX 或 provider 调用。事件准备与缓存锁未发现同类慢查询回流；生产 expansion queue 串行化也限制了正常 commitLock 竞争。

`MacClippySnippetExpanderRestoreTests.swift:172–210` 使用 production expander/injector 和可注入 named pasteboard；第 4 次 `currentContext` hook 内确认板上已经是展开后的 own bytes，在字段 identity/caret 仍有效时发布 newer user copy，并明确断言 hook 执行、写入成功、Delete=0、Paste=0、新 bytes 保留。因此它并非“hook 未执行也通过”的测试。

但 `expansionDidFinish` 是 `expand` 的 defer 完成通知，取消也会触发；此测试没有直接断言 `afterPasteEvents=0`。此外 snapshot1 的第 4 次查询同样在预检阶段，其残留慢查询是最终 ownership 检查之后额外的第 5 次查询：在第 4 次 hook 改 clipboard 会让旧代码也提前取消。需补足成功路径的最终检查顺序/无额外慢查询证明，并保留 owned write 后改变 clipboard 的取消回归，防止重新引入旧错误仍保持测试绿色。这是回归敏感度缺口，源码顺序修复本身仍成立。

rollback / restore 继续使用成功写入时记录的 generation；失败写入或 cancellation 不以任意当前 changeCount 冒充 owned generation。已开始 Delete 的 commit 会完成对应 Paste，以避免只删不贴；这不承诺目标应用确实消费了事件，也不把 PID 等同于锁定具体控件。

**提交完成、gate close、stop 和缓冲输入的完整链**

`MacClippyPasteInjectionGate.swift:24–35` 只用短锁进行 admission；provider、trust、fresh AX 和事件投递不占用该锁，close 不等待它们。`MacClippyPasteInjector+Injection.swift:244–278` 的普通与已提交分支互斥，实际投递后统一进入 `completePostedEvents`（280–287）：gate 已关闭时可跳过 Did 通知，但 request 自己的 `afterPasteEvents` 仍恰好调用一次。准备失败、预检拒绝或未进入投递分支没有该 completion。其语义是事件投递完成，不是 OS/目标控件消费确认。

Snippet 的 completion 绑定 request.identifier，`+Expansion.swift:125–145` 只为匹配 commit 解锁，然后安排缓冲回放或停止清理。`+DeferredInput.swift:13–38,105–139` 复制事件，优先使用事件中有效的 `.eventTargetUnixProcessID`，缺失时在 commit 中使用 captured committing PID；FIFO 串行 drain 保留 keyDown/keyUp/flags 次序。取消 Tab 会先回放被吞 delimiter，再回放捕获事件。stop 关闭 gate、推进 lifecycle/input generation 并清空 pending；不会等待 commitLock 或 provider，但 active commit/replay 的资源寿命仍受 ASR-P1-005 阻断。

实际测试路径：`MacClippyPasteInjectorGateTests.swift:7,84,182` 分别覆盖准备/上下文阻塞时取消且 completion=0，以及事件投递阻塞时 close 可返回、Did 被抑制而 completion=1。`MacClippySnippetExpanderRestoreTests.swift:150` 覆盖第一个 Delete 后 close，仍保持 7 Delete + 1 Paste。`MacClippySnippetInputCommitTests.swift:67` 覆盖阻塞 Delete 期间 stop、缓冲 keyDown/keyUp/flags 与目标 PID，期望完整 14 项投递序列。这些测试持有 expander 至结尾，不能覆盖最后持有者提前释放。

所有上述测试本轮 `NOT RUN`。源码全局符号检索显示显式 `afterPasteEvents` 注入计数集中于三个 gate 测试；不同请求互不串 completion、beforePaste=false、Delete 准备失败及 deinit 资源回收仍缺直接计数/寿命回归。synthetic focus 的 stop 也不能证明 native `AXObserverRemoveNotification` 调用的严格时延上界；off-main stop 仍需 main.sync。

**ASR-P2-002：真实 CGEvent 解码与 UTF16 caret**

`MacClippySnippetExpander+Input.swift:321–375` 从 CGEvent 取得最多 64 个 UTF16 code units，显式把合法 high/low surrogate 组合为非 BMP scalar，保留普通 BMP 与 combining scalar；孤立 high/low surrogate 被跳过。`222–249` 在单次 event 内按 Character 的 UTF16 长度累积 prefix offset，在分号处将此偏移加入 cached caret，后续 trigger/delimiter 也使用 UTF16 长度。有效的 ASCII/CJK/emoji prefix 不再被忽略。

`MacClippySnippetExpanderContextCancellationTests.swift:235–254,349–358` 真正调用 `CGEvent.keyboardSetUnicodeString`，把 `A先😃;email ` 送入 `handle(type:event:)`，并检查 7 Delete、1 Paste、PID 101、caret=11；没有以 `processKeyForTesting(String)` 冒充生产 decoder 覆盖。256–272 行还发送含孤立 high surrogate 的原始 code units，并检查有效字符仍能触发展开。先前 String-only 测试仍在，但不是这里的主要 Unicode 证据。

fresh context 的 identity、非空 selection 和精确 selection 等值检查仍保留（`+Expansion.swift:31–34,76–87`），input/lifecycle generation 未削弱；`MacClippySnippetFocusContext.swift:66–80` 以 UTF16 预测 caret，无法解码的输入使预测失效，近期较旧采样不覆盖已有前向预测。

剩余覆盖：combining prefix、孤立 low surrogate、连续 high/high/low 或尾端畸形单元、64-unit 边界、跨事件 emoji 后再键入 trigger 的真实 CGEvent 路径。混合单事件测试覆盖三类有效前缀，但没有逐类独立矩阵。SyntheticFocus 的 fresh/cached selection 都按 decoder 输出推进，不能证明目标控件如何处理畸形 UTF16，也不能代替真实 AX 时序；实际 fresh caret 不一致时源码仍取消。未据此新增 Unicode 产品缺陷。

**ASR-P1-001：历史 schema、安装/迁移与内层认证**

`MacClippyBackup+KeyValidation.swift:218–232` 先检查列存在性；schema008 缺 `representation_refs_auth` 时选择 NULL alias，旧 representation 缺 itemIndex 时按旧单 item 语义读取。Raw legacy record 可在没有 roster 时校验 body/blob；当前 wrapped record 仍要求有效 roster。`ClipboardRecordEnvelope.swift:17–29` 见到 `recordFormatVersion` 就按 envelope 解码且只接受支持版本，不会在未知版本时退回 raw legacy 解码。Roster 校验仍绑定 recordID、itemIndex/sortOrder、UTI、state、blob ID 和 ciphertext digest。

`MacClippyBackup.swift:212` 起按所需文件、外层 size/hash、内容/key 认证、数据库健康度验证；只读连接不对备份源迁移。`MacClippyBackup+Restore.swift:57–63` 在创建/恢复 live staging 前先拒绝缺 key，再验证输入；正确 key 下仅迁移 staging 副本，通过 journal 保存旧 live components，安装后由新打开成功的调用方 finalize。Missing-key preflight 可返回 `keyCompatible=false`，不代表 install 获准。

`MacClippyBackupHistoricalSchemaTests.swift:9–105,235` 已改成真实 `clipboardItem` kind，使用前八次 migration；与允许读取的原始 base 001–008 schema 对照相符。Fixture 含旧格式加密 body、inline 加密 representation、4096 字节 spill blob、image body/blob。它检查 correct/missing/wrong key、备份源逐文件字节不变，在 populated live root 先验证缺/错 key 拒绝，然后实际 `installIntoLiveRoot`，检查 journal，重新创建 ClipboardStore 触发迁移，list 两条记录并检查 kind/preview、读取 text/image body、playback representations、spill/image blob 原字节，最后 finalize 并确认源不变。它已经不再用 body-only 读取掩盖错误 kind。

仍未完成的历史兼容证明：恢复后没有执行 search query；search fixture 本身是当前迁移创建的空库，不能证明旧搜索内容恢复或重建。List 已走 metadata 转换，但没有单独 `metas` 断言；inline representation 虽被 playback 读取/解密，未断言最终 data 精确相等，也未断言旧 itemIndex=0。Image blob 仅有 8 字节 PNG header，能测试加密 blob 安装/读取，不能证明有效图片解码。缺/错 key 的 populated live 验证只保留先前列表标记，没有完整 live-root byte fingerprint。这些是 fixture/验收缺口，不是已经确认的 restore 数据损坏。

`MacClippyBackupCompatibilityTests.swift:128–224` 新增 wrapped record 的 missing roster、corrupt roster、unsupported envelope version 三类拒绝路径；变更 sqlite 后重新计算 manifest 对应 DB 的 bytes/SHA256，使用正确 key，因而真实到达内层校验，而非被旧外层 digest 提前挡住。校验结果虽统一映射为 DB checksumMismatch，源码控制流能区分此次确实执行了内层解码/认证。每例调用 validate 与 install，检查 source 全部常规文件 bytes 不变、live `keep.txt` 保留、没有 journal；但这个 live root 仅 sentinel，并非完整已有四库及 blobs，尚缺完整 populated live-root 不变性负例。没有把仅 SQL kind mismatch 或仅 body 解码当成旧库兼容证据。

**ASR-P2-001：累积重试、资源边界与真实 provider fixture**

`MacClippyPasteboardReadRetryState.swift:127–147` 保存最新累积 change，同时保留 attempts；未完成槽以 `(itemIndex, UTI)` 定位，identity 还包含 generation、source app、截断信息和 ordered types。`PasteboardObserverLifecycle.swift:132–167` 从这一累积 change 继续 reread，检查 lifecycle 与真实 changeCount，再更新状态，最多四次观察尝试（含初次）。`PasteboardCapture+Reading.swift:102–148` 在保留既有 items 的副本上更新精确槽，读取前后检查取消/version，合并时把已经保留的 bytes 计入限制；新 generation 不与旧 snapshot 混合。stop 清空 retry state 并推进取消 generation。

边界包括初读最多 32 items、每 item 64 UTIs、UTI 256 bytes、单 representation 128 MiB、总 change 256 MiB；下游另有单 record representation 数量界限。初读的三次 generation 尝试共享 0.2 秒软 deadline 和 16 次额外读取预算，单槽 data/string 重试最多三次；后续 observer poll 获得新的 reader budget，但受 observer 总尝试数限制。nil 可重试，空 Data 是已到达的有效内容，oversized 标记不继续重试。Deadline 限制启动后续读取，不能中断已进入的 AppKit/第三方 provider 调用，也不能阻止 provider 在返回前分配内存；同 generation 的迟到有效结果可以保留，不宣称硬性 0.2 秒响应保证。

新增 `MacClippySystemPasteboardRetryTests.swift:9–76,98–116` 使用 `NSPasteboard.withUniqueName()`、真实 SystemPasteboardReader 和生产 observer。两个 item 使用相同 UTI；AppKit 的 `NSPasteboardItemDataProvider` 回调保存原 promised item 并记录次数，测试没有手工调用回调或返回伪造 snapshot。初读两项均 nil；在 polls 之间对原 item0 调用 setData，检查 board 的 bytes 与 changeCount 不变；下一 poll 检查 item0 已恢复、item1 仍待定的累积状态。随后同样 materialize item1，最终断言顺序、两份不同 payload、原 strings、单次 delivery，以及各 provider callback 恰好一次。

这是源代码层面可确认的 **AppKit 进程内 named-board 集成覆盖**；与 mock reader 测试明确区分，且不代表本轮已运行，更不代表任意第三方应用/provider 的跨进程兑现行为。其他已读 mock 和 SystemReader 测试分别覆盖 cancellation、generation churn、bounds；尚未形成“真实 provider 部分恢复后再 churn/cancel/耗尽累计预算”的完整组合。

新 fixture 有具体的确定性风险：第 17 行把 `pollInterval` 设为 60，但 observer.start 经 `PasteboardObserverLifecycle+Controls.swift:126,226–234` 按 poll policy 重新赋为 0.05/0.40 秒并启用自动 timer。手工 poll 因此不是唯一推进 retry 的来源；自动 tick 可在两次 materialize 之间多消耗尝试，`delivered` 的测试数组也没有独立隔离自动回调与读取。这是可定位的测试竞争/稳定性风险，未观察到失败，不另立生产 P2。可通过测试专用 timer 控制保持手工 poll 的确定性，同时继续使用真实 reader/observer 路径。

**snapshot1→snapshot2 差异覆盖**

共 7 个修改文件、1 个新增文件，没有删除。1002 行完整 diff 已审阅；八个变更文件均全文阅读，且沿调用链检查了未变化的关键实现。[完整差异](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/snapshot1-to-snapshot2.diff)、[每文件前后 SHA256](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/changes.json)。下表路径均以 `MacClippyKit/` 为前缀。

| 变更文件 | 已检查的变更 |
| --- | --- |
| Sources/MacClippyPlatform/MacClippySnippetExpander+Expansion.swift | 去除 beforePaste 的 fresh AX；匹配 identifier 后再清 pending |
| Sources/MacClippyPlatform/MacClippySnippetExpander+Input.swift | UTF16 surrogate 解码；单事件 prefix offset |
| Tests/MacClippyCoreTests/MacClippyBackupCompatibilityTests.swift | 重算外层 digest 后的三类内层负例 |
| Tests/MacClippyCoreTests/MacClippyBackupHistoricalSchemaTests.swift | 正确 schema008/kind、加密多类型数据、实际 live install/reopen |
| Tests/MacClippyPlatformTests/MacClippySnippetExpanderContextCancellationTests.swift | 真正 CGEvent Unicode 输入及 PID/caret 断言 |
| Tests/MacClippyPlatformTests/MacClippySnippetExpanderRestoreTests.swift | owned write 后 hook 写 newer copy；named board 注入 |
| Tests/MacClippyPlatformTests/MacClippySnippetExpanderTestSupport.swift | context 计数/hook；锁外执行回调 |
| Tests/MacClippyPlatformTests/MacClippySystemPasteboardRetryTests.swift（新增） | 两个相同 UTI promised item 分轮兑现的真实 reader/observer fixture |

**后续身份与全局未完成项**

control revision 40 明确重新开放九个当前 Package 路径做 lint 结构整理：PasteInjector+Snapshot、SnippetFocusContext、SystemPasteboardRetryTests、PasteboardObserverRetryTests、SnippetExpanderRestoreTests、SnippetExpanderContextCancellationTests、BackupCompatibilityTests、BackupHistoricalSchemaTests、PasteInjectorGenerationOwnershipTests；revision 41 又分派 ASR-P1-005。snapshot2 仍是有效历史证据，但其结论不能自动转移到这些修改及新 helper。最终冻结后必须验证新 manifest，再审精确差异、真实 App caller 与相应确定性回归。

交接时 revision 44 转述 Native 已修复 ASR-P1-005，报告完成 red/green lifetime 回归，并新增 deterministic timer seam。这些可变修复 **`REPORTED_FIXED_UNREVIEWED`**，本轮没有读取、执行或认可。下一身份须检查：排队 replay 是否持有责任对象至完整回放与 native tap/source 清理；最后持有者释放、取消 Tab、stop/close 的确定性时序；真实生命周期资源断言是否超出 `startForTesting`；timer seam 是否只控制调度而继续走 production reader/observer；以及上述九路径结构变动和 AX/Unicode 覆盖补充。原 snapshot2 中 ASR-P1-005 仍为 `CONFIRMED_SOURCE`，不因后续修复转述而改为通过。

本轮没有关闭全局 ASR-P1-003/P1-004、ASR-P2-003/P2-004/P2-005 或 packaging path 等 App/runner 问题，也没有检查 runner retention/LaunchServices/telemetry/CI 的最新集成。Runtime 恢复、全局 callback generation、锁屏 GUI、目标控件实际收件、最终构建和独立运行验收留给 root 后续分派。

受保护 installed PID 50253 与 `.general` 未被本审阅者操作或检查运行状态；没有真实键盘事件、App 启停或 UI 操作。按 control，GUI 仍锁定；macOS 14 明确 `NOT RUN`（用户要求不补环境），24/72h soak 未执行。完成本有界静态复审后释放审阅 lane，不等待 App gates。

**逐文件阅读账本**

本轮全文阅读 59 文件（40 source / 19 tests，共 12,450 行），部分阅读 3 文件（321 行），其余 187 个 manifest 条目未在本轮作内容审阅；全量 hash 校验不计作内容阅读。未为复写首轮结论而通读其余 174 个先前未全文阅读文件。完整路径、SHA256 和实际阅读区间见 [全文清单](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/full-reads.json)、[部分清单](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/partial-reads.json)、[249 项 coverage](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/coverage.json)。

部分阅读：`ClipboardStore+Capture.swift:1–187`、`ClipboardStore+SearchProjection.swift:1–85`、`PinboardSnippetStores.swift:85–109,282–305`，均在 `MacClippyKit/Sources/MacClippyCore/`。报告没有把这些文件登记为全文阅读。


全文阅读：`MacClippyKit/Sources/MacClippyCore/`（18 文件）

```text
BlobStore.swift
ClipboardRecordEnvelope.swift
ClipboardStore+BatchReads.swift
ClipboardStore+Migrations.swift
ClipboardStore+RepresentationRoster.swift
ClipboardStore+RepresentationValidation.swift
ClipboardStore+Representations.swift
ClipboardStore.swift
MacClippyBackup+Create.swift
MacClippyBackup+FileIO.swift
MacClippyBackup+KeyValidation.swift
MacClippyBackup+Restore.swift
MacClippyBackup+Snapshot.swift
MacClippyBackup+Validation.swift
MacClippyBackup.swift
MacClippyBackupSettingsPolicy.swift
MacClippyPasteboardInputLimits.swift
PathsDatabase.swift
```

全文阅读：`MacClippyKit/Sources/MacClippyPlatform/`（22 文件）

```text
MacClippyPasteInjectionGate.swift
MacClippyPasteInjector+Injection.swift
MacClippyPasteInjector+Snapshot.swift
MacClippyPasteInjector.swift
MacClippyPasteboardPollPolicy.swift
MacClippyPasteboardPreparation.swift
MacClippyPasteboardReadRetry.swift
MacClippyPasteboardReadRetryState.swift
MacClippyPasteboardWriteSentinel.swift
MacClippySnippetExpander+DeferredInput.swift
MacClippySnippetExpander+Expansion.swift
MacClippySnippetExpander+Input.swift
MacClippySnippetExpander+Lifecycle.swift
MacClippySnippetExpander.swift
MacClippySnippetExpansionPlanner.swift
MacClippySnippetFocusContext+Models.swift
MacClippySnippetFocusContext.swift
MacClippySnippetKeyPoster.swift
PasteboardCapture+Reading.swift
PasteboardCapture.swift
PasteboardObserverLifecycle+Controls.swift
PasteboardObserverLifecycle.swift
```

全文阅读：`MacClippyKit/Tests/MacClippyCoreTests/`（4 文件）

```text
MacClippyBackupCompatibilityTests.swift
MacClippyBackupHistoricalSchemaTests.swift
MacClippyBackupRestoreTransactionTests.swift
MacClippyBackupValidationTests.swift
```

全文阅读：`MacClippyKit/Tests/MacClippyPlatformTests/`（15 文件）

```text
MacClippyPasteInjectorGateTests.swift
MacClippyPasteInjectorGenerationOwnershipTests.swift
MacClippyPasteInjectorRestoreTests.swift
MacClippyPasteInjectorTargetTests.swift
MacClippyPasteInjectorTests.swift
MacClippyPasteboardObserverLifecycleTests.swift
MacClippyPasteboardObserverRestartTests.swift
MacClippyPasteboardObserverRetryTests.swift
MacClippyPasteboardReadRetryStateTests.swift
MacClippySnippetExpanderContextCancellationTests.swift
MacClippySnippetExpanderRestoreTests.swift
MacClippySnippetExpanderTestSupport.swift
MacClippySnippetInputCommitTests.swift
MacClippySystemPasteboardReaderTests.swift
MacClippySystemPasteboardRetryTests.swift
```

机器可读交接：[处置记录](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/dispositions.json)、[新增 finding](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/findings.json)、[覆盖缺口](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/coverage-gaps.json)、[交接摘要](/tmp/macclippy-phase6-package-rereview2-20260925T2222Z/review-summary.json)。

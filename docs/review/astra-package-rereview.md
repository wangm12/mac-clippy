**MacClippy package 静态复审 v1.0 — 2026-09-25**

本轮是 gpt-6-astra 对指定不可变 MacClippyKit 快照的独立、有限静态复审，**不是最终验收**。快照仍有 **ASR-P1-002（P1）和 ASR-P2-002（P2）的确定源码缺陷**。ASR-P1-001 的缺列问题、ASR-P2-001 的累计重试问题已能从源码解释为修正，但仍需独立执行验证；历史库夹具另有确定错误，不能据此关闭备份验收。没有对当前 App、scripts 或整个产品作“无 P0/P1”结论。

所有测试执行状态均为 **NOT RUN**。以下“源码确认”表示控制流、数据流和断言检查，不代表编译通过、测试通过、真实事件送达或数据恢复成功。用户/native 汇报的 full 634 / 4 skipped / 0 failures，以及最终 completion helper 拆分后的 focused 6 / 0，仅作为背景记录，未由本 reviewer 执行或复证。

**范围、身份与证据**

| 项目 | 本轮记录 |
| --- | --- |
| 快照根目录 | `/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/macclippy-phase6-package-review-89xx52f7` |
| 清单 | `/tmp/macclippy-phase6-package-review-snapshot.json`；快照内 `manifest.json` 内容相同 |
| 创建时间 | `2026-09-25T21:43:06.952771+00:00` |
| 文件数 | 248 |
| 内容 SHA256 | `e79634a6be8a71ab40918c92991627039fb111631c380838f153898fabdc7e8f` |
| 摘要算法 | 对清单中按路径排列的 entries，以 compact、sort_keys JSON 编码后计算 SHA256；每项含 path、bytes、sha256 |
| 兼容性基线 | git `79e987a982f15f9193392c9af98b66465efd5ee2`，只读历史对象 |
| 实际完整阅读 | 74 个文件：51 个 source、23 个 test/support，共 14,737 行 |
| 其他 package 文件 | 174 个本轮未完整复审，逐项列入 coverage/unreviewed 元数据；248 个文件的哈希校验不等于 248 个文件的源码审查 |

开始和结束均独立读取全部 248 个快照文件，核对字节数和 SHA256，未发现差异，重算内容 SHA 与清单、control 一致。本轮 source/test 只从上述快照读取。历史 git 对象只用于核对原始 DDL、记录类型及 envelope 兼容性。原 [全源码报告 v1.0](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/astra-source-review.md)、[E2E 报告 v0.4](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/astra-e2e-results.md) 和 followup notes 已读作上下文，没有覆盖它们。

control revision 24–27 已接收本轮发现，并授权 native 恢复修改 Package；`affectedPathsInvalidatedByRemediation = true`。**本报告只证明原快照的状况，不能转移到正在修复的分支。** 残留问题及其关联 injector/snippet/backup/provider 新回归需要在新快照重新检查。收到该指令后未读取任何可变 Package/App/scripts，也未等待其完成。

**各项处置**

| 范围 | 源码结论 | 处置与验证状态 |
| --- | --- | --- |
| ASR-P1-001，真实旧 schema 备份 | 原缺列查询修正：RESOLVED_BY_SOURCE_INSPECTION_AWAITING_TESTS | 不作验收关闭；历史夹具 kind 错误，缺真实 live-root 安装及 image/spilled 恢复证据 |
| ASR-P1-002，owned generation | PARTIALLY_REMEDIATED_OPEN；残留 P1 为 CONFIRMED_SOURCE | 最后一次慢 AX 查询仍在最后 owned-count 检查之后，具体见下 |
| ASR-P2-001，累计 lazy provider 重试 | RESOLVED_BY_SOURCE_INSPECTION_AWAITING_TESTS | 同 generation 累积值已保留；真实 same-UTI、多 item 分轮 provider 回归仍缺 |
| ASR-P2-002，UTF16 anchor | PARTIALLY_REMEDIATED_OPEN；残留 P2 为 CONFIRMED_SOURCE | 实际 CGEvent 解码丢代理对；同事件 prefix+trigger 不计事件内前缀 |
| afterPasteEvents | 原快照请求级完成链已完整静态检查 | 指定 gate-close 分支恢复 Did == 0，accepted commit 仍可完成清理；执行 NOT RUN，受后续关联改动影响需复审 |

历史夹具错误和新增边界测试需求属于现有问题的验收缺口，不新增全局严重性编号。平台延迟、真实 AX 语义、事件接收效果列为待验证项，没有当作已确认性能缺陷。

**ASR-P1-002：最后一次 AX 查询仍可越过 clipboard generation 检查**

定位均为上述快照中的仓库映射路径：

- `MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector+Injection.swift:188`：核对 owned changeCount，随后调用 `beforePaste()`；成功后直接投递 matching Paste。
- `MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+Expansion.swift:94`：`beforePaste` 的 `validateAndCommitTrigger` 内再次执行 fresh `validateRequestFocus/currentContext`，这是可能阻塞的 AX/context 查询。
- 同一 `MacClippyPasteInjector+Injection.swift:191` 至 Paste 投递之间，没有该慢查询之后的新 ownership 检查。

具体顺序为：写入 snippet 内容并记录 owned generation → permission / preflight context 查询 → 最后一次 owned-count 检查 → `beforePaste` 内 fresh AX 查询 → 接受并 Delete → Paste。若用户在最后 AX 查询阻塞时复制新内容，而查询返回相同的有效 field/caret，snippet 仍删除 trigger，随后 Paste 的是用户刚复制的内容。原快照未把“最后慢查询之后仍拥有 clipboard”纳入最终编辑准入条件。这是确定的控制流缺口，不依赖一般性的 OS 调度猜测。

建议确定性回归：用 named pasteboard，在 **beforePaste 内最后 pre-delete 的 currentContext 调用**中将 clipboard 改成 `user-new`，仍返回相同且有效的 PID、field、selection。断言 Delete == 0、Paste == 0、未 admission 时 afterPasteEvents == 0，并保留 `user-new`。测试应明确命中这一次查询，不能只在较早的 `validateCommitContext` hook 中修改 clipboard。最后慢查询须在最终短 ownership/admission 检查之前完成；一旦 Delete 已被接受，就必须完成 matching Paste，不能靠删除后再取消 Paste 来修补。

已正确修正的部分也已核对：plan 携带成功写入的 `ownedChangeCount`；失败/取消仅携带能证明归属的可选 restore count；manual fallback、提交和 rollback 使用该确切 generation，不再把任意“当前 count”当作自身 generation。`MacClippyPasteboardPreparation.swift`、snapshot 恢复、sentinel 与 GenerationOwnershipTests 的完整实现和断言均已读。新增测试覆盖在 commit validator 中产生新 copy、取消写入、权限查询返回不可用期间产生新 copy等场景，并保留新数据、抑制全局/目标事件；它们没有覆盖上述最终 fresh AX 边界。

本 P1 已立即通过 ordinary commentary 上报；control revision 24 明确接收并派发修复。没有编辑实现。

**ASR-P2-002：预测 anchor 的方向正确，实际事件入口仍有两处残留**

`MacClippyKit/Sources/MacClippyPlatform/MacClippySnippetExpander+Input.swift:323` 用逐 UTF16 code unit 的 `Unicode.Scalar` 转换生成 String。非 BMP 字符（如 emoji）的两个 surrogate 均不是独立 scalar，会被 `compactMap` 丢弃。单独 emoji 事件得到空串，production `noteInputText("")` 会使预测 selection 失效；与普通字符混合时会少算 UTF16 长度。紧随其后的有效 trigger 因 anchor 缺失或位置错误而被拒绝。新 emoji 测试直接把 Swift String 交给 `processKeyForTesting`，monitor 测试直接调用 `noteInputText`，均绕过了真实解码路径。

同文件 `:224` 的另一个边界是同一个 CGEvent 携带 `hello;email`。处理分号时取的是事件开始前的 cached selection，整个事件的 `noteInputText` 在遍历后才发生，因此 anchor 少算事件内 `hello` 的 5 个 UTF16 units。随后普通 delimiter 产生的 fresh caret 与预测位置不相等，正常展开被误取消。此结论适用于当前 String 处理入口，无须假设真实键盘每次一定只发一个字符。

建议使用 synthetic `CGEvent.keyboardSetUnicodeString`，经 `handle(type:.keyDown,event:)` 进入 production 解码/处理路径，配 fake key poster，禁止真实 OS 投递。分别覆盖 emoji 后快速 trigger、ASCII/CJK/emoji 前缀与分号 trigger 同事件、多次分号以及随后 delimiter；按 UTF16 位置断言成功，并保留 stale field/caret、missing selection、input generation 变化时不编辑的断言。root revision 25–26 已接收这两个边界。

原修正保留的安全条件已核对：production focus monitor 以 `text.utf16.count` 推进 collapsed selection；未知/空输入使预测失效；fresh selection 必须存在且与预期相等；PID、field、lifecycle/input generation 与 pending request ID 仍被检查。快速输入后短窗口内，采样器不会用较旧、较小的 collapsed caret 覆盖预测位置；mouse/navigation/selection/focus 变化会使候选失效。普通自动 delimiter 留给目标应用输入，预期 anchor 包含其 UTF16 长度；被拦截的 Tab 不应包含在已输入 caret 中。

两处 RestoreTests 的 selection expectation 从 0 改为 7 是合理修正：`;email` 为 6 个 UTF16 units，后随普通空格为 1，fresh caret 应为 7。成功路径仍要求 7 个 Delete 和 1 个 Paste；失败路径仍要求不删除、不粘贴，并保留 selection 不符/缺失及排队后 context 改变的防护。此处没有发现为了通过测试而移除安全断言；问题在于缺少 production Unicode 入口和事件内前缀的回归。

**每次 injection 的准入、完成和 replay**

完整阅读了 injector 主体、Injection、Snapshot、gate、Preparation、snippet Input/Expansion/DeferredInput/Lifecycle、focus monitor、key poster、planner 及相关指定测试。原快照的调用顺序和责任如下：

| 阶段 | 源码行为与判断 |
| --- | --- |
| 请求构造 | text/content 入口把 `afterPasteEvents` 存入本次 `InjectionRequest`；injector operation lock 串行化写入操作，不把 callback 放进全局通知状态 |
| 准备 | snapshot/provider、permission、fresh context 查询不占用 gate 的状态锁；gate 关闭不等待这些外部调用结束，但不能中断已进入的同步 provider/AX 调用 |
| 准入前取消/失败 | preparation 失败、权限 fallback、写入失败、gate 关闭或 `beforePaste == false` 均不调用 afterPasteEvents；恢复仍按确切 owned generation，不能覆盖新 copy |
| snippet 接受编辑 | fresh 检查后短暂持有 lifecycle 状态锁，并持有 commitLock 跨越 Delete/Paste；校验 request ID、generation、cached focus 后设置 committing ID/PID；Delete event 准备失败走自身 cleanup，不伪造 Paste 完成 |
| 已接受的编辑 | Delete 开始后即使 gate 关闭，也走 committed Paste；该分支保证 matching Paste，避免只删除 trigger。此性质不消除上文准入前最后 AX 的 P1 |
| 投递完成 | `MacClippyPasteInjector+Injection.swift:280` 的 completion helper 在 Paste events 的同步 post 调用之后执行；完成时观察到 gate 已关闭的分支不发外部 Did，但仍调用本请求的 afterPasteEvents |
| snippet 完成 | `finishCommitAndUnlock(request)` 检查 committing request ID，清除状态并释放锁，启动 replay 或继续 stop cleanup；不再依赖 Did 通知来释放 accepted commit |
| 输入缓存/replay | committing/replay 期间复制并按顺序缓存 keyDown、keyUp、flagsChanged，保留 flags；使用事件已捕获的有效 target PID，缺失时使用本次 committing PID；串行 replay 持续排空期间新增输入 |
| stop/restart | stop 关闭 gate、使 generation 失效且不等待 commitLock；已接受编辑/replay 尚未结束时延迟 event tap teardown；cleanup 未完成不允许生产 restart，完成后再结束 stop |

normal 和 committed 两个 Paste 分支各只有一个 completion 调用点；函数分支互斥。未准入路径没有伪完成，snippet 的 exact request ID guard 防止其他请求错误解锁。原快照从同步控制流支持“每个已投递请求一次完成”；它并非接收应用已经消费事件或完成文本插入的确认协议。条件式 Did 检查也不应被表述成跨所有并发调度的全局通知屏障。

重点测试的断言没有被弱化：

- `MacClippyPasteInjectorGateTests.testClosingGateDoesNotWaitForInFlightEventPostOrPostDidAfterward` 使用唯一的 `object: injector` observer。阻塞 event post 后关闭 gate，仍要求 close 非阻塞、结果为 injected、Did == 0、afterPasteEvents == 1。先前 Did == 1 确为生产通知回归，不能解释成跨测试污染；该快照已保留修正后的严格断言。
- GateTests 的 blocked preparation 和 slow commit-context 检查要求 close 及时返回、未准入 completion == 0；blocked write 情况要求取消并按归属恢复。
- `MacClippySnippetExpanderRestoreTests.swift:150` 的 Delete 中途关 gate 场景保留完整 7 Delete + 1 Paste，并指定 PID 101。
- `MacClippySnippetInputCommitTests.swift:67` 阻塞首个 Delete，缓存 Esc down/up，再 stop，随后缓存 Shift flags/down/up/unshift；要求 stop 不等提交结束，动作顺序为 7 Delete、Paste、6 个输入事件，输入 PID 均为 101。取消的 Tab 路径也保留后续 Esc/x 的重放顺序。

仍需在最终版本验证两个并发请求的 callback 归属与次数、正常完成的严格顺序、false-beforePaste/失败事件准备不回调且可再次使用、陈旧/重复 completion 不解锁新请求，以及最后 owner 释放/stop/restart 与 replay 交错。源码中 weak capture 与异步 replay 的生命周期不能替代这些执行证据。本轮未发现可单独确认的 deallocation 缺陷，不将其升级为新问题。

PID 定向只能说明事件被投递到该进程；它不锁定目标应用内部的 AX element。已接受阶段 mouse/focus 变化、目标退出、不同应用处理 keyUp/flags 的行为，以及真实插入效果属于系统测试范围。App 的调用顺序、恢复时机、recipient proof 未从可变源码推断。

**ASR-P1-001：历史 DDL、envelope、密钥与只读恢复验证**

旧基线 `ClipboardStore.swift` 的迁移 001–008、records/representations DDL、append 编码以及 inline/spilled 写入均已与新代码核对。旧 records 没有 `representation_refs_auth`；旧 representations 以 `(record_id, uti)` 为主键，没有 `item_index`。后续 source_app_name/primary_blob_id 属于旧迁移，不能以“只降 manifest version”的当前 schema 夹具替代。原始 `Models.swift` 的有效 record kind 为 `clipboardItem`，原始 ClipboardRecord 枚举使用 JSON Codable，旧保存路径直接加密该 raw record。Crypto 层使用 AES.GCM combined envelope；本轮未改变密钥或任何真实数据。

`MacClippyBackup+KeyValidation.swift:218` 起按 PRAGMA table_info 检测列：缺 refs auth 时选择 `NULL AS representation_refs_auth`；旧 representations 缺 item_index 时按 0 读取，排序仍保留 sort_order/UTI。因此原缺列 SELECT 故障在该快照源码上已消除。ClipboardStore 的旧迁移标识和语句仍保留，新增迁移在 staged copy 上添加 roster/itemIndex；旧多 UTI 单 item 按 itemIndex 0 迁移。

`ClipboardRecordEnvelope` 在没有 recordFormatVersion 时只走真实旧 raw record 解码；带版本标识必须是支持的 wrapped version，未知/损坏格式不会偷偷回退。当前 wrapped record 要求 authenticated roster；旧 raw record 可以无 roster，但存在 roster 时仍必须验证。roster 只接受支持版本，绑定 record ID、排序后的 itemIndex/sortOrder/UTI/state/blobID/payload digest；v1 对 itemIndex 有相应约束。当前格式缺 roster、roster 与行不符、非法 payload state/组合、重复 itemIndex+UTI，以及 inline 密文损坏均不能因旧 schema 兼容分支而绕过认证。

| 输入/分支 | 源码行为；执行均 NOT RUN |
| --- | --- |
| 非空真实旧库 + 正确 key | 解密旧 raw record 和其他 encrypted payload，schema-aware 查询不访问缺列；可继续结构和引用验证 |
| 错误 key | AES.GCM open failure 映射为 keyMismatch，不能通过生产安装 |
| 缺 key | 只读 validate 可以给出 keyCompatible == false；`installIntoLiveRoot` 先抛 keyRequired，早于 live root 恢复/创建/替换操作 |
| legacy 空库、无可认证 payload | keyCompatibilityUnproven；不能仅凭结构健康推断 key 正确 |
| malformed/缺失/错配的必需 roster | fail closed；不会降级成未认证 legacy |
| 旧 image/spilled 引用 | 路径须安全、blob 必须存在于 manifest，相关 blob bytes 仍须认证；源码链支持继续处理，不据此声称此类恢复已通过测试 |
| 生产 restore | 验证 key、manifest、内容、DB health、必需数据库与 references 后，复制到 transaction staged storage，在副本上打开/迁移，再安装并保留 rollback；源备份不应被迁移 |
| `restore(from:to:)` | 是结构验证后的复制 API，与要求密钥的 `installIntoLiveRoot` 授权边界不同，不能拿复制成功代替生产恢复验收 |

`PathsDatabase` 的 readOnly 分支不执行创建目录、WAL 写入设置或 migrations；KeyValidation/reference/health 读取走只读数据库。staging 将数据复制到单独目录，ClipboardStore、SearchStore、PinboardStore、SnippetStore 在 staging/live 副本上打开。Pinboard/Snippet strict 解码和数据库健康检查也已完整阅读。readonly 打开后的实际文件字节、sidecars 与 migration/reopen 行为仍须由独立回归证明，本轮没有打开运行中的数据库。

**历史 fixture 的确定错误与证据缺口。** `MacClippyKit/Tests/MacClippyCoreTests/MacClippyBackupHistoricalSchemaTests.swift:74` 插入 `kind = "clipboard"`，与真实基线的 `RecordKind.clipboardItem.rawValue == "clipboardItem"` 不符。`ClipboardStore.swift:276` 的 meta 转换会拒绝该 kind；`ClipboardStore+BatchReads.swift:87` 的 metadata 路径使用该转换，而 `body(for:)` 只解 envelope。因此 fixture 的 body 成功不能证明正常列表/metadata 可读取。这是 **CONFIRMED_SOURCE 的夹具错误**，不是对真实生产旧库另报一个恢复缺陷。

该历史测试当前只放 text，blobs 为空；调用的是复制 restore，并在目标上打开当前 store。它没有证明 `installIntoLiveRoot` 的真实迁移/安装路径，也没有真实旧 image、inline/spilled 组合的验证；snapshotBytes 未覆盖有内容的 blobs。现有 RestoreTransactionTests 使用当前 store 生成数据库，能验证 rollback/cleanup 控制流断言，但不能填补旧 schema 缺口。测试中“先复制再 body 解密成功”的范围必须明确。

下一轮应以基线真实 DDL/迁移记录、正确 kind、raw envelopes 和真实 encrypted blob 构造库：涵盖 text、image、inline representation、spilled representation；正确 key 走实际 live-root 安装、finalize 和 fresh reopen，核对 metadata/list、ordered representations、body/blob bytes；错误/缺 key 保持 live markers 和源 snapshot 全部 bytes 不变。另需对缺 roster、损坏 roster、重放/交换 roster、未知 envelope version 的备份重算 manifest checksums，再调用生产 validate/install，证明不是仅靠外层 checksum 拒绝。现有 store-level roster 测试不能替代这一层备份回归。

**ASR-P2-001：累计恢复、generation 与预算**

`MacClippyPasteboardReadRetryState.update` 将 reread 返回的累计 change 保存为下一轮 originalChange，同时保留尝试计数，只缩小仍 unavailable 的 item/UTI slots。因此 A 在第一轮恢复、B 在下一轮恢复时，下一轮从含 A 的 snapshot 继续，不再回退到最初缺 A 的版本。identity 检查包含 changeCount、source app、truncatedItemCount 和有序 item.types；slot 使用 itemIndex+UTI，同 UTI 的不同 item 不合并。

Observer 从累积 snapshot 请求重读，在 reader 前后检查 lifecycle，并核对实时 changeCount；generation 变更丢弃旧 pending，下次从新 generation 完整采样。production reader 在每次 native data/string 请求前后检查取消和 generation；若采样期间变化，不把该 payload 合入旧 snapshot。每次 merge 先计入已有 bytes，再考虑新增 payload，所以累计 maxChangeBytes 不会因分轮读而重置。mapper、capture persistence、representation itemIndex/排序和 authenticated roster 保留 item 边界；dedup identity 包含适用的 itemIndex、UTI、state 和数据顺序。

| 预算/边界 | 原快照行为 |
| --- | --- |
| 一次初始 read | 最多 3 次 generation 尝试，共享 0.2 秒 deadline 和 16 次 provider retry 预算 |
| 单个 data/string 方法 | 默认最多 3 次尝试；string 是 data 无结果时的后备，两者共享该次 snapshot 的 retry/time budget |
| 后续 observer reread | 每次获得新的有限 snapshot budget；跨 poll 总尝试默认 4 次，包含初次，故最多 3 次 reread |
| 预算耗尽 | 保留已恢复 bytes，未恢复 slots 继续表示 unavailable；observer 输出当前累计结果，不伪造 payload |
| oversized/空数据 | oversized 明确保留状态且不无限重试；空 Data 是有效 present，不能当作 nil |
| 取消/stop/restart | 已进入同步 native provider 不可强制中断；返回后 lifecycle/generation 失效则拒收；pending 清除，不把旧 partial 混入新一轮 |
| deadline | 限制发起后续调用；已经进入的慢 native provider 可能超时才返回，同 generation 且未取消的有效返回值可保留。这是软预算，不是原生调用硬中断保证 |

`testObserverAccumulatesStaggeredRepresentationsAcrossRetriesForRepeatedUTIs` 检查 mock reader 的 lazyA/lazyB 分轮恢复，第二轮只请求剩余 slot，并验证四份 payload 与一次 delivery。其重复 UTI 在测试开始时已经 present；不是“两个 item 的同一 UTI 均 lazy、分两轮恢复”的 production provider 回归。SystemPasteboardReaderTests 已有真实 named-board provider 的 churn、慢 unavailable、迟到有效值与取消断言；它们不组合成该指定累计边界。

需要补 named-board、真实 NSPasteboardItem provider 的两个同 UTI item，分轮返回不同 bytes；验证中间累计状态、最终 payload identity/顺序、单次 delivery。再覆盖已部分恢复后预算耗尽、累计字节上限、取消以及新 generation 的组合；新的版本不得继承旧 bytes。root revision 26 已接收该需求。本轮未确认第二个 provider 实现缺陷，不能把测试缺口当作失败实测。

**完整阅读范围与原始 deferred 文件**

用户点名的 9 个 deferred 文件已全部完整阅读，包含各自实现、断言和 test support，不仅阅读 diff：

| 类型 | 仓库映射路径 |
| --- | --- |
| source | `MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardPreparation.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorTests.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteInjectorTargetTests.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardObserverLifecycleTests.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpanderContextCancellationTests.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpanderRestoreTests.swift` |
| support | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpanderTestSupport.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetExpansionPlannerTests.swift` |
| test | `MacClippyKit/Tests/MacClippyPlatformTests/MacClippySnippetInputCommitTests.swift` |

此外完整阅读 HistoricalSchema、GenerationOwnership、Gate、BackupCompatibility/Validation/RestoreTransaction/SettingsPolicy、AuthenticatedRepresentationRoster、ObserverRetry/Restart/Recovery、ReadRetryState/SystemReader 的测试文件，并沿 source 检查其对应链条。全部 74 个完整阅读文件及 SHA/行数/与基线的关系由以下元数据逐项列明；174 个其余 package 文件不继承本轮批准，原 v1.0 广泛审查也不能覆盖它们后来发生的变化。

- [完整阅读文件清单](/tmp/macclippy-phase6-package-rereview-full-reads.json)
- [248 文件逐项覆盖状态、SHA、行数和基线关系](/tmp/macclippy-phase6-package-rereview-coverage.json)
- [174 个本轮未完整复审文件](/tmp/macclippy-phase6-package-rereview-unreviewed.txt)
- [开始完整性验证](/tmp/macclippy-phase6-package-rereview-integrity-start.json)、[结束完整性验证](/tmp/macclippy-phase6-package-rereview-integrity-end.json)
- [确定残留问题原始记录](/tmp/macclippy-phase6-package-rereview-findings.json)、[处置与待验证项](/tmp/macclippy-phase6-package-rereview-dispositions.json)
- [历史 git 对象读取范围和哈希](/tmp/macclippy-phase6-package-rereview-base-context.json)

剩余 package 范围包括未重读的 retention/reconciliation/search repair、attachment maintenance、其他 policies/tests 和 process-crash harness；不得把这次针对修复链条的 74 文件复审说成 package 全量重审。涉及 restore/capture 的已读主链及其边界在上文逐项说明，其余间接 maintenance 交互留给最终全量审查。

**交接与执行边界**

Root 下一轮需要在 native/Python 完成、全局 source generation 固定后重新取得清单和新快照，复审上述残留修复、历史夹具修正、新增 production-entry/provider 回归及所有受影响 completion/restore 链，再独立运行针对性和完整套件。后续测试必须绑定最终源码/产物身份；早先 634/6 的汇报不能覆盖其后的改动。源码关闭、测试通过与真实系统验收应分别记录。

本轮没有读取当前 mutable App/scripts，因而 ASR-P1-003、ASR-P1-004、ASR-P2-003/004/005/006 的当前修复状态、App queue/capture/restore 集成、E2EBuildIdentity/QueuePasteModel/Snippet 及 project 配置剩余审查仍由 root 的后续流程负责。旧报告中的性能风险也没有在此通过静态查看转成 pass。

未执行 build、test、App、GUI、产品进程控制、commit/push/tag/release；没有改实现、测试或配置。仅写本报告及 `/tmp/macclippy-phase6-package-rereview-*` 元数据。未操作受保护的已安装 PID 50253；桌面锁定状态仅引用 control，未尝试解锁或 UI 操作。macOS 14 为 **NOT RUN per explicit user**；真实 App、24h、72h 验证均未执行。

本轮到此结束并交接，不等待可变 App/Package 修复。原快照中的 P1/P2 保持上述状态；新版本是否消除它们，必须由后续快照和独立执行证据决定。

# MacClippy subagent 详细复审与修复验证（2026-10-01／02）

**修复状态（2026-10-02）：SR-01～SR-06 六项已修复，并补充回归测试。** Package 正常测试 725 项、完整 TSan 测试 1,159 项均零失败；TSan 中 5 项按配置跳过。Shipping 与 E2E Release 构建通过。100k 候选 ID 枚举由约 2.8 秒降至 98～99 ms；10k 真实 Runtime 搜索的 9 组查询各测 21 次，最高 P95 为 40.02 ms。详细改动、证据与兼容性说明见文末“修复与复测”。

## 复审基线（2026-10-01）

以下保留修复前的发现与证据；问题位置链接指向本次修复开始前的工作区快照。该阶段确认 1 个 P1、5 个 P2，其中 4 个 P2 是上一轮 patch 引入的回归或规模性能问题。原有 10k 空结果搜索、灾难性正则回溯和普通共享附件所有者场景的修复有效，当时仍需处理下列问题。

本轮按用户要求派出 3 个独立 subagent，分别审查搜索/分页、正则/采集隐私、容量清理/附件并发；主 agent 审查其余重构、工程来源清单与验证证据，并独立复跑所有下列复现类别。审查以本次 patch 开始时的工作区快照为基线，避免把已有用户改动误归到本次 patch。

| 编号 | 严重性 | 归属 | 已确认问题 |
|---|---|---|---|
| SR-01 | P1 | 原有，尚未解决 | 隐私规则只查主投影；其他 item/图片、文件的伴随明文/备用 HTML 可绕过 |
| SR-02 | P2 | patch 回归 | 新增受保护的共享附件所有者后，总容量计账会多删较新历史 |
| SR-03 | P2 | patch 回归 | 合法规则集同步编译约 2.8 秒，发生在主线程启动路径 |
| SR-04 | P2 | patch 回归 | 带换行、tab 或 Unicode 空白的 URL 被新的组合搜索 scope 排除 |
| SR-05 | P2 | patch 规模性能 | 大历史库 type scope 重复扫描/排序，100k 的候选 ID 枚举约 2.8 秒 |
| SR-06 | P2 | 原有，尚未解决 | 全选 FTS 分页没有 revision 校验，并发重建索引可返回重复 ID |

没有确认 P0。以上计数不重复计算同一容量计账问题的多个反例，也不把合作式预算或未测平台当作缺陷。

## SR-01：隐私规则没有检查全部待保存的文本

位置：[PasteboardObserverProcessing.swift:296](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyPlatform/PasteboardObserverProcessing.swift:296)，另一分支在 304 行；主内容选择：[PasteboardMapping.swift:98](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyPlatform/PasteboardMapping.swift:98)；持久化调用：[MacClippyRuntime+Maintenance.swift:36](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippy/MacClippyRuntime+Maintenance.swift:36)。

规则 `token\s*=` 可以拦截单条 `token = secret`，但 observer 只对 projection.searchableText 匹配。投影优先选择图片、文件，或第一个普通文本；完整 representations 则包含其他 item 与格式。以下 4 个合成输入都进入生产 admission handler，保留 secret 的原始文本表示：

| 输入 | 主投影文本 | 结果 |
|---|---|---|
| 第一个 item 为 ordinary，第二个为 secret | ordinary | 交付，secret 保留 |
| PNG 与 secret 明文同时存在 | nil | 交付，secret 保留 |
| file URL 与 secret 明文同时存在 | nil | 交付，secret 保留 |
| 普通 plain text 与含 secret 的 HTML 同时存在 | ordinary | 交付，secret 保留 |

主 agent 独立重跑 observer 探针，结果一致。探针使用真实 Release Platform observer 与模拟 reader，没有触碰系统剪贴板；确认的是敏感表示通过隐私检查并送入待持久化路径。Runtime 源码随后全量传入 representations，没有第二次文本排除检查。本轮没有跑完整 Runtime 数据库落盘 round-trip，不能把模拟 reader 描述成真实系统互操作验证。

三个相关文件与 patch 前相同，因此归为原有隐私缺陷。修复应检查每个 item 中保留的、可解码的 text/HTML/RTF，任一命中则阻止整代采集；整代共享资源预算，避免把每个表示的独立 20 ms 预算累加成新的停顿。回归应覆盖上述 4 例及真实 store 读回不含 secret。

证据：[subagent 结果](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/regex/observer-results.json)、[主 agent 复核](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/observer-verified.json)、[探针源码](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/regex/observer-probe.swift)。

## SR-02：受保护共享附件仍占用未保护预算，导致多删

新增抵扣：[RetentionPolicy+TotalCap.swift:149](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/RetentionPolicy+TotalCap.swift:149)；重新计账仍使用初始保护集合：[同文件:77](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/RetentionPolicy+TotalCap.swift:77)。

总容量预算只计未保护记录与其引用的去重 blob。新代码只根据物理 reclaimedBlobIDs 抵扣附件；附件转为只被受保护记录引用时，文件须保留，但应退出未保护预算。当前代码混用了这两种口径，且在整轮删除后才重算，保护集合也没有刷新。

确定性交错：初始 old image 与 newer text；cap=105 bytes，恰好容纳 newer text。在首次 commit fence 中新增共享 image owner，并由 protectedIDsProvider 将其设为受保护记录。

| 算法 | 提交次数 | old image | 新受保护 image | newer text | 最终未保护载荷 |
|---|---:|---|---|---|---:|
| patch 前 | 1 | 删除 | 保留 | 保留 | 105 bytes |
| 当前 patch | 3 | 删除 | 保留 | **误删** | 0 bytes |

两者都保留 shared blob，问题是多删历史。主 agent 独立运行 before/after 探针得到相同结果。小 cap 用于简化复现，同一计算路径用于实际配置。

另有两个同类原有反例：已有 pinned owner 共享附件，以及提交前将大型 inline record 保护。两者 before/after 都会多删更新文本；作为 SR-02 覆盖，不另加问题数。

修复应分别维护未保护预算的引用与全部物理引用，并在保护/所有权变化后、规划下一批删除前更新计账。直接恢复旧快照扣减会重新打开原来的未保护新 owner 提前结束漏洞；仅在整轮后重算也无法挽回已多删的记录。

基线探针复制准确的 before total-cap 算法，仅省略跨模块不可访问的候选认证调用；fixture 为已认证 current-format。当前路径实际链接生产 Release Core，未改生产删除代码。

证据：[主 agent before/after](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/new-protected-owner-verified.json)、[原有反例复核](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/retention-verified.json)、[详细证据说明](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/retention/review-notes.md)。

## SR-03：正则缓存编译阻塞启动主线程

同步编译：[MacClippyBoundedRegexMatcher.swift:16](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/MacClippyBoundedRegexMatcher.swift:16)；规则初始化：[SmartText.swift:322](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/SmartText.swift:322)；主线程启动：[MacClippyRuntime+Lifecycle.swift:89](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippy/MacClippyRuntime+Lifecycle.swift:89)。

128 条规则，每条重复 800 次 `\p{Letter}`，长度 8,000 UTF-8 bytes。规则合法，均在新设的 128 条/8,192 bytes 限额内。before struct 只在匹配时编译；新初始化同步编译整组规则，20 ms 匹配预算对此没有约束。

| 测量 | before 初始化 | 当前初始化 |
|---|---:|---:|
| subagent 3 样本 | 0.016–0.084 ms | 2,760–2,793 ms |
| 主 agent 3 样本 | 0.012–0.561 ms | 2,781–2,800 ms |

探针自然运行于主线程，仅记录 Thread.isMainThread，没有人为等待或主线程同步调度。实际 Runtime.start 明确切至主线程，然后同步构造规则；Runtime 初始化也构造一次。故可确认新增同步阻塞，未测完整 App 启动端到端总时长，不能把 2.8 秒当作整个启动的完整数字。

defaults 更新还会在 captureQueue 重建同一组规则，包括 patterns 未改变时；编译成本已测得，其对采集持久化排队的影响是调用链推断。

应在后台准备规则，复用未变化的 pattern 集合，并在规则更新等待期间保持隐私保护。需要分别限制或度量编译与匹配成本。本例没有把 RegexBlocklist 原来已有的语法校验成本误算为新回归。

证据：[subagent 对照](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/regex/compile-comparison-results.json)、[主 agent 对照](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/compile-verified.json)、[before 摘录与探针](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/regex/compile-comparison.swift)。

## SR-04：组合 URL 搜索与原 grammar 不一致

新 scope 调用：[ClipboardStore+SearchProjection.swift:66](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/ClipboardStore+SearchProjection.swift:66)；SQL URL 谓词：[同文件:234](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/ClipboardStore+SearchProjection.swift:234)。

正常公开 API append 文本 `\nhttps://example.com/scopereview\n`，默认 detectedTypeJSON=nil，查询 `scopereview type:url`：

| 输入前后缀 | 原 grammar 匹配 | 原 FTS 命中 | 新 scoped 命中 |
|---|---|---:|---:|
| 无空白、普通空格 | 是 | 1 | 1 |
| tab、换行、NBSP、全角空格 | 是 | 1 | **0** |

SQL TRIM 只处理普通空格；Swift URL 判断会先移除 whitespacesAndNewlines。scope 在 grammar 之前排除了有效记录，后续判断无法恢复。纯结构化查询此前已有此问题；本次 scope 将其带入裸词+结构化组合查询。

复现由生产 ClipboardStore.append 与 SearchStore 写入、读取，不需要伪造 SQL。主 agent 独立复跑全部 6 组前后缀，结果一致。修复应与 Swift URL 判断一致，或只使用保守的候选筛选，保证没有假阴性。增加上述空白和 detectedTypeJSON=nil 回归。

证据：[subagent](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/search/scope-results.jsonl)、[主 agent](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/url-results.jsonl)。

## SR-05：大历史库的 ID scope 分页近二次增长

SQL keyset：[ClipboardStore+SearchProjection.swift:35](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippyKit/Sources/MacClippyCore/ClipboardStore+SearchProjection.swift:35)；Runtime 每页先枚举所有符合条件 ID：[MacClippyRuntime+SearchScope.swift:51](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippy/MacClippyRuntime+SearchScope.swift:51)。

type:text 查询计划采用 content_kind 单列索引，每个 512 条分页重新建立排序树，id > ? 没有成为索引范围。虽称 keyset，实际仍反复扫描、排序剩余候选。每个 History 返回页都完整枚举 scope，随后才执行 FTS，即使 UI 只需 16 条或裸词只有一个命中。

| 合法文本记录数量 | 完整 scope 的 warm 3 样本范围 |
|---:|---:|
| 1k | 1.21–1.33 ms |
| 10k | 24.88–30.69 ms |
| 20k | 85.29–88.71 ms |
| 50k | 706.74–725.87 ms |
| 100k | 2,749.20–2,796.54 ms |

这是候选 ID 枚举阶段，不是 Runtime 全页时间，也不是 P95。默认普通 History cap 为 10k；问题限定于大量受保护记录、保留/导入超默认容量及 Core 大数据集，不能据此宣称默认 10k 秒级变慢。

subagent 仅在独立 fixture 加 (content_kind, id) covering index，100k 枚举降为 102–106 ms。主 agent 通过 SQLite backup 复制合成 fixture，在自己的副本先移除、再添加相同探针索引，测得未加索引 **2,778–2,933 ms**，加索引 **101–105 ms**；计划变为 content_kind=? AND id>?，无临时排序。

应补适合该查询的索引/迁移，并减少继续分页时重复构造完整 scope；还须覆盖其他筛选组合，不能把这个索引当作所有条件的通用性能保证。探针索引没有加入产品或用户数据库。

证据：[规模样本](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/search/scope-scale-results.jsonl)、[subagent 索引对照](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/search/scope-index-results.json)、[主 agent 对照](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/scope-verified.json)、[主 agent 探针](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/scope-verify.swift)。

## SR-06：并发重建索引时全选游标可重复 ID

位置：[MacClippyRuntime+Selection.swift:87](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippy/MacClippyRuntime+Selection.swift:87)，组合查询同类路径在 150 行；[sortedIDs:19](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippy/MacClippyRuntime+HistoryPaginationProjection.swift:19) 只排序、不去重；[Dock selectionCount:159](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/before/MacClippy/MacClippyDockModel+LoadingPreview.swift:159) 使用原数组数量。

全选与新版 History 分页不同，只携带 rank/rowid，不验证 search index revision。实际 Release Core 按该循环读取 512 条同长 common body，在读取首 256 条后，将已经访问的一个 ID 同内容 upsert。revision 从 512 变为 513，记录得到新的 rowid，落到后续分页中：

- 最终收集 513 个 ID，只有 512 个唯一 ID。
- 重建的 ID 出现 2 次。
- 主 agent 独立复跑，结果一致；源码的 metadata 累加、sortedIDs 和 Dock 有序选择数组没有去重措施。

这是原有缺陷。复现运行了真实 Core 搜索及与 Runtime 相同的分页交错，**没有直接调用完整 Runtime 或操作真实 Cmd+A UI**；选择数虚高由已审查的下游数组使用推导，不宣称已测出重复粘贴。缺 revision 同时可能漏选，单纯 Set 去重不足以修复一致性。

应校验整个全选请求的 revision，并有界重试/取消失效快照，去重作为最后防线。回归应在真实 Runtime 全选中注入 page 间重新索引、删除与 OCR 更新。

证据：[subagent](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/search/selection-cursor-results.json)、[主 agent](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/selection-verified.json)、[交错探针](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/search/selection-cursor-probe.swift)。

## 已验证的修复与证据边界

普通恶性回溯及 nested lookahead 约 20 ms 停止；缓存和值语义、observer 串行更新未见回归。约 1 MiB 的 Unicode grapheme 输入可花约 70 ms，属于已披露的合作式预算边界，不当作硬实时违规。

搜索覆盖 prefix/infix、CJK/phrase、临时 scope 事务/清理、Unicode 来源/标签、旧来源名称回退、分页及取消。readonly 数据库 scoped 查询实测通过，已排除该疑点；临时表未改持久 index revision。Cmd+A 仍走旧未 scoped 路径，本轮没有量化真实 Runtime 全选性能，不新增重复的 FR-03 性能问题。

原普通未保护 shared owner 交错修复有效，删除 journal 与 lease 没有确认的新破坏。单次 10k × 1 KiB、只需删一条的 total-cap 探针 before 322 ms、after 637 ms，体现新增完整重扫成本；不是 P95 或 UI 卡顿证据。256 × 64 KiB 的 accounting 页请求 +1 ms 取消，约 20 ms 返回，不另列缺陷。

主 agent 核对拖拽 cache/preview/provider 提取前后行为一致；Runtime drag materialize 与表示读取重构保留原事务与验证逻辑。弱捕获、健康测试 hook 的锁封装与工程新文件来源清单未发现新的可复现问题。

重新计算 556 个 source/build inputs 的 SHA-256，与上一轮最终验证版本全部一致；HEAD 保持 79e987a982f15f9193392c9af98b66465efd5ee2。既有日志确认 Package TSan 700 项（4 跳过）、App TSan 426 项（1 跳过），0 失败且无 TSan 报告；Shipping/E2E Release 与 480 文件 lint 通过。本轮复核这些日志，未重跑全量 suite。现有测试通过没有覆盖本轮发现的反例。

本轮仅新增报告与忽略目录里的探针/合成 fixture，未修改生产源码、仓库测试、原始 benchmark 证据或真实用户数据。构建输入核验与日志解析见 [主 agent 核验记录](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-review-20261001/root/root-evidence-check.json)。完整 patch 与 before 快照保留在 [原 patch evidence](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/full-review-patch-20261001/patch-only.diff)。

macOS 14/Intel 实机、真实 NSPasteboard/接收应用互操作、完整 Runtime 交错测试、可见 UI 帧率、长期 soak、签名/notarization 仍需要后续验证。竞品资料沿用 [原全库与竞品评审](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/full-review-2026-10-01-zh.md)，本轮没有做新的竞品同机 benchmark，因此不提供竞品速度/内存排名。

## 修复与复测（2026-10-02）

本节描述六项发现的最终补丁。搜索与正则 subagent 负责各自的实现及回归测试；主 agent 实现容量清理修复，容量 subagent 独立复核。构建、完整测试与最终 Release 探针由主 agent 串行运行，避免并发编译影响性能测量。

### 六项修复

| 编号 | 最终行为 | 主要实现与验证 |
|---|---|---|
| SR-01 | 映射及持久化之前检查每个 item 中保留的文本表示；任一命中、无法可靠检查或预算耗尽，拒绝整代采集。普通二进制图片等不作为文本解码。 | [隐私过滤](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/PasteboardPrivacyTextFilter.swift:12)；[8 项隐私测试](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Tests/MacClippyPlatformTests/MacClippyPasteboardPrivacyTests.swift:10)，包含生产 observer → 加密 ClipboardStore 的合成 round-trip。 |
| SR-02 | 单独计算未保护记录的逻辑容量；blob 失去最后一个未保护 owner 后退出预算，即使受保护 owner 或 lease 仍保留物理文件。提交时校验记录 revision 与保护集合，变化则整批跳过并重新计账。 | [逻辑计账](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/RetentionPolicy+TotalAccounting.swift:3)、[提交与重算](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/RetentionPolicy+TotalCap.swift:27)；[10 项容量竞态测试](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Tests/MacClippyCoreTests/MacClippyTotalCapRaceTests.swift:5)。 |
| SR-03 | 规则构造不再同步编译；observer 在专用后台队列准备规则，相同 pattern 集合复用缓存，失效任务按版本取消。等待准备期间拒绝采集。 | [后台准备](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/PasteboardObserverTextRulePreparation.swift:23)；[7 项正则预算测试](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Tests/MacClippyCoreTests/MacClippyRegexBudgetTests.swift:6)及准备/更新交错测试。 |
| SR-04 | SQL URL 筛选复用原有 Swift URL grammar，普通空格、tab、换行、NBSP、全角空白的行为一致。 | [URL 谓词](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore+SearchProjection.swift:243)；Core 与 Runtime 覆盖结构化查询、组合查询和全选。 |
| SR-05 | 013 迁移增加 `(content_kind, id)` covering index 和记录 revision；继续分页复用绑定 query、Runtime 与 revision 的不可变 scope，相同 scope 不重复写 TEMP 表。元数据变化或来源名称解析改变候选集合时，使旧游标失效。 | [迁移与 revision](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore+Revision.swift:17)、[scope 复用](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyRuntime+SearchScope.swift:49)；索引计划、交错 scope、readonly、元数据和来源名称变化回归通过。 |
| SR-06 | 全选请求在每批及结束时校验 FTS 与记录 revision；失效时最多完整尝试 4 次。取消返回空选择，持续写入返回明确错误；最终 ID 去重并保持顺序。 | [真实 Runtime 全选路径](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyRuntime+Selection.swift:18)；[4 项 Runtime 交错测试](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippySelectionSearchRevisionTests.swift:69)，验证分页期间重建索引、全局 rank 变化、组合查询、取消与有界重试，且不解密记录正文。 |

SR-01 的 HTML/RTF 检查采用本地有界文本扫描，检查源文本、实体/转义解码和可识别的标签/控制边界变体。没有引入 native 富文本 importer、WebKit、外部资源加载或主队列同步等待。主 agent 另外发现并修复了连续 HTML 标签造成多重换行的边界反例；`token\n=` 对 table 单元格之间的规范化文本现在能命中，见 [独立 Release 复核](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/html-boundary-final-results.json)。这不等同于实现完整的浏览器 HTML/CSS 布局语义。

兼容性变化：**启用文本隐私规则时，未知 HTML 命名实体、不支持的 RTF 控制/编码、RTFD 包装或规则尚未准备完成，会拒绝本次采集。** 未启用文本规则时保持原采集行为。每代共享 20 ms 合作式预算及各 1 MiB 的编码字节/文本累计额度，预算不按表示数量叠加；这些限制不承诺操作系统层面的硬实时抢占。后台编译也可能持续数秒，但不再阻塞启动调用线程。

SR-02 保留候选认证、footprint 复核、物理 owner 证明、删除 journal 与 lease 机制。稳定情况下按实际删除结果增量扣减容量，不再每次 commit 后完整重扫；持续变化时最多重启规划 3 次，无法取得稳定预算则留待后续 maintenance。记录 revision 的 UPDATE trigger 使用 null-safe 值比较，认证的 no-op 自写不会使自己的快照失效，真实 primary-blob backfill、表示或 payload 改动会触发重算。

013 迁移也使旧测试 fixture 的“旧 schema”边界需要明确：表示身份及附件索引迁移测试现在固定在 012 之前，不再依赖 `dropLast()`。修正了这些 fixture 后完整 suite 通过；没有改 lint baseline 或降低 Swift 编译警告门槛。

### 完整验证

| 验证 | 结果 | 证据 |
|---|---|---|
| Package 正常测试，strict concurrency | Core 393 + Platform 332，共 725 项；4 跳过，0 失败 | [日志](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/package-full-final.log) |
| Package Thread Sanitizer | 725 项；4 跳过，0 失败，无 TSan race 报告 | [日志](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/package-tsan-final.log) |
| 完整 App Thread Sanitizer，启用 10k scale 测试 | 434 项；1 跳过，0 失败，无 TSan race 报告 | [日志](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/app-tsan-final.log)、[xcresult](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/AppTSanFinal.xcresult) |
| 正常 App 分页/scope/全选/10k scale 回归 | 28 项，0 失败 | [日志](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/app-focused.log) |
| Shipping / E2E Release | 两个 scheme 均构建成功，保留 warnings-as-errors | [Shipping](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/shipping-release-build.log)、[E2E](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/e2e-release-build.log) |
| 仓库固定版本 lint 与 diff 检查 | SwiftLint 0.63.2，490 文件，0 违规；diff 检查通过 | [lint](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/lint-final-pinned.log)、[工具版本](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/tool-versions.log)、[diff](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/diff-check.log) |

TSan 合计 1,159 项，5 跳过：Core 的私有 crash-worker 入口及两个 opt-in scale case、Platform 的 10k 生命周期循环、App 的真实 event tap。App 的实际 10k 搜索 scale case 已启用并通过；Core 的 100k 候选枚举另由下列 Release 探针验证。跳过项不计作已执行通过。

### Release 性能与独立复现

环境为 M4 Max、macOS 27.0.1、Xcode 27.0 / Swift 6.4。以下探针在全套构建与测试完成后串行运行，链接最终 Release Core/Platform；所有 fixture 均为合成、隔离数据。

| 测量 | 修复前证据 | 最终复测 |
|---|---|---|
| 100k `type:text` 候选 ID 全量枚举，3 个 warm 样本 | 主 agent 2,778～2,933 ms；每页存在临时排序树 | **97.90 / 98.75 / 99.28 ms**，196 页完整覆盖 100,000 ID；使用产品 covering index 的 `content_kind=? AND id>?` 范围，无临时排序。 |
| 128 条相同合法 8,000-byte 正则的主线程构造，3 样本 | 2,781～2,800 ms | **0.087 / 0.0068 / 0.0061 ms**。 |
| 128 条不同复杂规则的实际 observer 准备 | 主线程路径原先同步编译 | 规则构造 **0.131 ms**、observer 构造 **0.183 ms**、start 返回 **0.065 ms**；后台准备 **2,653 ms**，最长 readiness 查询 **0.0016 ms**；相同规则更新并采集 **0.125 ms**。等待期间无交付，准备后与复用后正常交付。 |
| 10k × 1 KiB total-cap，只需删除一条 | 上轮完整重扫版本单样本约 637 ms | 单样本 **307.33 ms**，1 次提交，保留 9,999 条。 |
| 256 × 64 KiB accounting 扫描，开始后 +1 ms 请求取消 | 上轮约 20 ms 返回 | **1.15 ms** 总耗时，取消检查后 **0.016 ms** 返回。 |

100k 数字是候选枚举阶段，后三项为有限样本，并非 UI 延迟或 P95。前后样本不是多轮受控统计实验，不将其扩展为所有筛选组合、设备或输入的速度保证。完整结果及断言见 [Release 探针汇总](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/release-probe-results.json)、[运行日志](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/release-probe-run.log)。

三个容量反例在 Release 下均已纠正：已有或新建受保护共享 owner 时，仅删除 old image，保留 newer text、受保护 owner 和物理 blob，最终未保护容量恰好 105 bytes；提交前动态 pin 后容量已合规时，两条历史均保留。URL 的 6 种空白输入均保留 scoped 命中，readonly scoped 查询通过。真实 observer 的 ordinary 控制正常交付，secret 控制及此前 4 种绕过均不交付；实际加密存储 round-trip 在上述 Platform suite 中验证。

真实 Release E2E App 使用 10k 文本及 25 条其他合成记录，通过生产 Runtime History 搜索 API 每组预热一次、测量 21 次。测量只包含数据库搜索调用时间，未包含键盘输入、IPC 往返或 UI 渲染时间。

| 查询 | limit | P50 ms | P95 ms | 命中数 |
|---|---:|---:|---:|---:|
| `common` | 50 | 16.83 | 17.47 | 50 |
| `uniquemarker9999` | 50 | 2.63 | 2.93 | 1 |
| `common type:text` | 50 | 37.64 | 40.02 | 50 |
| `uniquemarker9999 type:text` | 16 | 17.92 | 18.32 | 1 |
| `common type:image` | 50 | 9.59 | 9.96 | 0 |
| `common app:com.review.missing` | 50 | 30.58 | 31.41 | 0 |
| `common type:text` | 16 | 34.09 | 35.15 | 16 |
| `common type:image` | 16 | 9.64 | 9.87 | 0 |
| `common app:com.review.missing` | 16 | 30.98 | 31.48 | 0 |

全部通过 P95 ≤100 ms 的复测门槛，最高 P95 **40.02 ms**。runner 验证了 bundle、Release 配置、可执行文件、runID、隔离 root 和最终源码 digest，只启动及结束自己拥有的 E2E 进程。没有操作已安装 MacClippy、系统剪贴板或真实用户数据。原始样本和身份见 [Runtime benchmark](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/runtime-benchmark.json)。

### 补丁范围与验证边界

以本次开始前 582 文件的工作区快照为基准，本轮修改 27 个已有文件、新增 10 个 Swift 文件，共 37 个文件；工程文件仅增加全选回归测试的注册。`project.yml`、两个 Info plist 和 lint baseline 保持快照字节不变。没有提交、推送或发布。精确范围见 [本轮补丁](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/patch-only.diff)、[文件清单](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/patch-files.json)、[保留检查](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/preservation-check.json)。

最终 566 个 source/build inputs 的 SHA-256 为 `2dcea0dd0124d8881220c046f1725d2c108dfa2bc97757447048c114728fa787`；完整测试之后源码未变，E2E Release 内嵌并返回同一 digest。文档更新不参与该源码 digest。HEAD 保持 `79e987a982f15f9193392c9af98b66465efd5ee2`。核验记录见 [最终验证清单](/Users/mingjie/Documents/github/personal-projects/mac-clippy/build/subagent-patch-20261001/final-validation.json)。

本次已补上真实 Runtime 全选交错及 observer → store 的合成集成测试；真实 NSPasteboard/接收应用互操作、可见 UI 帧率、长时间 soak、macOS 14/Intel 实机和签名/notarization 仍未在本轮验证。这里完成的是六项已复现问题的补丁与回归验证，不能据此推导全平台发布就绪或竞品性能排名。

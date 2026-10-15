# MacClippy 全库与竞品评审：性能、稳定性

更新：后续 patch 已完成 FR-01 至 FR-05，修复与复测结果见文末；下方原始评审保留修复前证据。

评审日期：2026-10-01。评审对象是当前工作区，包含评审开始前已有的大量未提交和未跟踪改动；不是仅评审 HEAD。基准分支 `codex/core-reliability-hardening`，HEAD `79e987a982f15f9193392c9af98b66465efd5ee2`。本轮只新增评审文档、临时探针和测试证据，没有修复或改写产品源码。

## 判断

基础存储和生命周期防护已相当完整：采集背压、OCR 限流、图片降采样、跨数据库删除恢复、共享附件租约、错误密钥拒绝和恢复事务都有实现及回归覆盖。普通搜索在本机表现良好。当前工作区仍有两个需要优先处理的 P1，以及三个已确认的 P2，暂不建议把它视为可直接发布的状态。

最值得关注的性能结果是：**1 万条数据、使用 Dock 的 16 条分页大小，查询 `common type:image` 的中位耗时达到 9.35 秒**。它不是图片解码慢，而是先分页取全文命中，再在 Swift 中筛掉全部结果，重复进行 FTS 排序。另一个稳定性风险来自自定义隐私正则：29 个字符即可让合法规则的匹配超过 5 秒。

本轮没有确认 P0。测试通过和短时资源观察并不等于所有输入、所有 macOS 版本及长期运行都已验证。

## 范围与证据

| 项目 | 本轮覆盖 |
|---|---|
| 仓库清点 | 起始快照 571 个文件；生产 Swift 288 个文件、53,409 行；全库 Swift 静态检查另含测试 |
| 深入路径 | 剪贴板读取/异常桥接、规则过滤、采集/去重、搜索/分页、OCR、预览/缩略图、存储/迁移/删除、备份/恢复、Dock 请求取消、Snippet、CLI、CI/发布脚本 |
| 方法 | 全文件自动扫描、关键路径人工检查、完整现有单元测试、并发检测、Release 合成性能探针、独立测试程序的自然轮询采集 |
| 竞品 | Paste、PastePal、Maccy、CopyQ、Clipy、Raycast、Alfred、Apple Spotlight；官方文档、公开仓库和发布说明 |
| 明确边界 | 未逐行人工审读全部 53,409 行；未安装或同机跑竞品，因此不做竞品速度/内存排名；未操作真实接收应用来测试粘贴 |

环境为 Apple M4 Max，16 核 CPU、64 GB 内存、arm64；macOS 27.0.1（26A434）、Xcode 27.0（27A266a）、Swift 6.4。依赖 GRDB 7.11.1。质量检查使用仓库固定的 SwiftLint 0.63.2、XcodeGen 2.45.4，而非本机 Homebrew 的较新版本。

构建输入清单包含 547 个文件，内容 SHA-256 为 `ae0e5b36ff244f7cb82155b610a0716697e853312deca908f38c6d192f09fbbd`。Release E2E 可执行文件 SHA-256 为 `7058a17d78482ef052e9b73c085e271ce02c6106b243ffeac11ed2de34293196`。探针核验了 bundle ID、PID、运行目录、Release 配置和嵌入的源码摘要。

原始证据位于 [`build/full-review-20261001/`](../../build/full-review-20261001/)。该目录被 Git 忽略，保留在本机；本报告记录关键数值与方法以便长期阅读。合成 E2E 数据位于本轮新建的 `mce5-nd02_jze` 临时根目录，使用独立测试密钥和具名剪贴板。E2E 项目将条数上限覆盖为 200,000，以免测试新增数据被淘汰；基准实际只有 10,000 条文本，第二轮另有 25 条合成采集。这不是 shipping 配置的长期容量验证。

## 已确认的问题

| 编号 | 优先级 | 问题 | 用户或交付影响 |
|---|---|---|---|
| FR-01 | P1 | 当前工具链下正常 App 构建失败 | 默认构建无法进入测试和交付 |
| FR-02 | P1 | 自定义隐私正则无匹配预算 | 一条合法规则可长时间阻塞观察队列、拖住后续采集 |
| FR-03 | P2 | 高频词加低命中率筛选重复扫描/排序 | 默认容量附近的正常搜索可能等待数秒；16 条分页实测约 9.35 秒 |
| FR-04 | P2 | 总载荷上限仍使用过期共享引用计数 | 并发新增附件引用时错误计入“已回收”空间，提前停止清理 |
| FR-05 | P2 | 固定版本完整 lint 门禁失败 | 当前工作区不能通过仓库的质量门禁 |

### FR-01：正常构建被隐式强捕获诊断阻断

正常运行 `xcodebuild test`、保持 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 时，编译器报 `ImplicitStrongCapture`，退出码 65，测试未运行。四个文件的出错位置是：

- [`MacClippyAppDelegate+Startup.swift:110`](../../MacClippy/MacClippyAppDelegate+Startup.swift#L110)：外层后台闭包隐式强捕获 `self`，内层 `[weak self]` 与之冲突。
- [`MacClippyDockModel+LoadingPreview.swift:414`](../../MacClippy/MacClippyDockModel+LoadingPreview.swift#L414)：详情任务外层闭包及内层 MainHop 的捕获关系。
- [`MacClippyDockModel+SelectionAll.swift:25`](../../MacClippy/MacClippyDockModel+SelectionAll.swift#L25)：批量选取任务与内层 MainHop 的捕获关系。
- [`MacClippyDockView+HeaderSearch.swift:81`](../../MacClippy/MacClippyDockView+HeaderSearch.swift#L81)：GeometryReader 内动作回调对 `model` 的捕获；诊断构建还报告了第二处按钮回调。

本轮临时以**命令行构建参数**关闭 warnings-as-errors，才得以完成 App 单测和 Release E2E。没有更改工程设置。这些诊断测试通过不能替代正常构建通过；也不能据此宣称已证明内存泄漏，当前确认的是构建失败及捕获语义需要明确。

建议明确每层闭包的捕获及生命周期预期，保持 warnings-as-errors 门禁，并把当前及最低支持工具链加入 CI 矩阵。验收条件是无需覆盖该设置即可通过 App Debug 测试与 Shipping/E2E Release 构建。

证据：`app-tests.log`、`app-tests.xcresult`、`app-tests-diagnostic.log`、`e2e-release-build.log`。

### FR-02：合法正则会阻塞采集观察队列

[`SmartText.swift:352`](../../MacClippyKit/Sources/MacClippyCore/SmartText.swift#L352) 每次重新构建 `NSRegularExpression` 并对完整文本执行 `firstMatch`。现有校验检查语法，不限制匹配复杂度。它从 [`PasteboardObserverProcessing.swift:295`](../../MacClippyKit/Sources/MacClippyPlatform/PasteboardObserverProcessing.swift#L295) 的串行观察路径调用。

实际复现使用原文件中的规则实现、Release 优化编译和合法规则 `^(a+)+$`：

| 输入 | 匹配耗时 |
|---|---:|
| 16 个 `a` + `!`，共 17 字符 | 2.35 ms |
| 20 个 `a` + `!`，共 21 字符 | 24.13 ms |
| 24 个 `a` + `!`，共 25 字符 | 372.62 ms |
| 28 个 `a` + `!`，共 29 字符 | 超过 5 秒；测试进程到时被终止 |
| 32 个 `a` + `!`，共 33 字符 | 超过 5 秒；测试进程到时被终止 |

这是规则执行的复现，未向真实系统剪贴板写入危险文本。默认规则列表为空，影响发生在用户设置或迁移了这类自定义规则后。观察队列被阻塞期间，后续轮询、规则更新和暂停命令的队列处理都会延后；中间剪贴板代次无法靠事后重读完整追回。`stop()` 本身有立即改变生命周期的保护，**本轮没有实测主线程卡死**。

建议规则变更时编译并缓存；为实际匹配引入可执行的操作/时间预算，验证进度回调取消机制，或使用复杂度可控的正则子集/引擎；预算耗尽应按隐私规则失败关闭并给出可理解的错误。单纯把匹配放进另一个异步队列、等待 timeout，不能终止已经运行的正则工作。回归应覆盖上述短输入、长文本、连续代次及规则修改。

证据：`regex-probe.swift`、`regex-results.json`。

### FR-03：筛选为空的搜索比普通搜索慢几个数量级

[`MacClippyRuntime+HistoryPagination.swift:290`](../../MacClippy/MacClippyRuntime+HistoryPagination.swift#L290) 先以 `context.limit + 1` 取得裸词全文命中，再在 Swift 中应用类型/来源等结构化条件。若条件筛掉全部候选，它会一直翻页到全文命中集耗尽。每一页又执行 [`SearchStore+Terms.swift:123`](../../MacClippyKit/Sources/MacClippyCore/SearchStore+Terms.swift#L123) 的 `ORDER BY rank, rowid`。

本轮 SQL 执行计划明确显示该排序使用 `USE TEMP B-TREE FOR ORDER BY`。仅按 rank 排序的对照计划没有这个临时排序，但直接删除 rowid 排序会改变游标和稳定顺序，不能作为未经验证的修复。分页大小又恰好绑定 UI 返回条数；[`MacClippyDockModel+HistoryPagination.swift:15`](../../MacClippy/MacClippyDockModel+HistoryPagination.swift#L15) 的实际大小为 16，空结果需要处理约 589 批候选。

在 10,000 条包含同一常见词的文本上：普通 `common` 搜索 P95 16.86 ms；`common type:text` P95 20.45 ms；`common type:image` 以 50 条为 limit 时约 3.28 秒，以 Dock 的 16 条为 limit 时中位 9.35 秒。该输入属于有效查询，当前测试仅验证高命中率的组合筛选和唯一词，不覆盖这一尾部情形。

生产 Dock 在后台加载，因此应描述为结果等待和存储竞争，而非直接认定 UI 主线程被冻结。每次 SQL 与 metadata 读取都持有 `storeLock`，可以影响同时采集或其他存储操作；本轮未量化这种竞争。取消检查发生在批次和候选之间，未配置可中断当前 SQL 的取消机制。

建议优先把可索引的 type/app/date 条件下推到 metadata 与全文索引的联合查询；独立设置候选扫描批次，避免 16 条展示页导致反复排序；保留正确游标、去重和 revision 语义，处理扫描预算和 SQL 取消。中文及 ASCII 子串 fallback 也应纳入数据规模/文本长度测试。验收建议是在同一 10k 语料上，对高命中率、零命中率和低命中率组合查询均设 P95 ≤100 ms 的目标；这是建议目标，尚未达到，也不是竞品实测。

证据：`search-benchmark.jsonl`、`search-query-plans.txt`、`runtime-benchmark.jsonl`、`runtime-page16-benchmark.json`。后者仅 5 个正式样本，报告中位数和范围，不将其包装成高置信度 P95。

### FR-04：总容量清理未使用实际回收结果

[`RetentionPolicy+TotalCap.swift:131`](../../MacClippyKit/Sources/MacClippyCore/RetentionPolicy+TotalCap.swift#L131) 在删除后递减扫描开始时的 `remainingBlobReferences`，降到零就扣除 blob 字节。删除接口已经提供 `reclaimedBlobIDs`，该路径却没有依据这个实际结果进行扣减。`expectedFootprints` 验证了候选本身，不能证明其他记录未新增该 blob 的所有权。

复现通过公开生产 Core API 建立两个图片记录、每个 blob 4,096 字节，并在第一次 `withCommitFence` 中为待删除 blob 新增一个引用。这是确定性的并发交错注入，不是概率性压力测试：

| 项目 | 结果 |
|---|---:|
| 每个加密 blob 的实际大小 | 4,124 bytes |
| 总载荷上限 | 4,257 bytes |
| 完成后的存活载荷：各 inline footprint + 去重 blob | 8,514 bytes |
| 清理提交次数 | 1 |
| 状态 | 新共享所有者和另一原记录都存活；两个 blob 都仍存在 |

这确认当前一次执行提前结束且高于自己的载荷口径上限，未观察到错误删除仍被引用的 blob 或数据损坏。产品默认总载荷上限为 4 GiB，复现降低了配置上限以使用小型数据；相同计算路径适用于实际上限。Runtime 维护与采集可交错，而清理计算与最终提交之间没有长期独占锁。

建议按 `deletion.reclaimedBlobIDs` 计算实际释放的 blob 空间，并在 ownership/protection/revision 变更后重新核算当前预算；注意新增 inline 数据、受保护共享引用和活动读取租约。测试至少覆盖本例、跨页共享、保护状态变化和不可立即删除的 blob。与现有 ImageCap 修复复用概念和回归形状。

证据：`core-review-probe.swift`、`retention-repro.jsonl`。这与旧评审已修复的 **ImageCap** 问题是两条不同路径。

### FR-05：完整 SwiftLint 有四处门禁错误

使用正确的 SwiftLint 0.63.2、现有 baseline 和 `--strict`，排除缓存权限限制后，changed-file 门禁确认：

- [`MacClippyDockCard.swift:551`](../../MacClippy/MacClippyDockCard.swift#L551)：文件 551 行，阈值 400。
- [`MacClippyRuntime+ClipboardActions.swift:473`](../../MacClippy/MacClippyRuntime+ClipboardActions.swift#L473)：文件 473 行，阈值 400。
- [`MacClippyRuntime+ClipboardActions.swift:67`](../../MacClippy/MacClippyRuntime+ClipboardActions.swift#L67)：函数体 53 行，阈值 50。
- [`ClipboardStore+Representations.swift:55`](../../MacClippyKit/Sources/MacClippyCore/ClipboardStore+Representations.swift#L55)：函数体 64 行，阈值 50。

这些是交付/可维护性问题，本轮没有据此声称运行时性能变差。建议按职责抽取实现，保持门禁和 baseline 的含义，不以扩大 baseline 掩盖本轮新增问题。门禁自身的 5 个 fixture 测试通过。

证据：`lint-confirmed.log`、`lint-full.log`、`lint-gate-tests-confirmed.log`。

## 性能实测

### Core 搜索

链接当前 Release 的 `MacClippyCore.o` 与 `GRDB.o`，探针以 `swiftc -O` 编译。使用磁盘 SQLite/WAL，逐条通过 SearchStore 插入；每条约 240 个 UTF-8 字节，含英文重复词、中文和唯一标记。语料逐步增至 1k/10k/100k。每种查询先预热 1 次，再采样 21 次，返回上限 50；P95 采用 nearest-rank。测试时未同时运行重构建或其他本轮重型测试。不是冷盘、长文档或 UI 绘制测量。

| 查询 | 1k P50 / P95 | 10k P50 / P95 | 100k P50 / P95 |
|---|---:|---:|---:|
| 高频英文 `common` | 1.38 / 1.44 ms | 15.40 / 15.57 ms | 144.89 / 146.95 ms |
| 唯一词 `uniquemarkerN` | 0.38 / 0.41 ms | 2.41 / 2.47 ms | 28.11 / 28.54 ms |
| 英文子串 `phab`，早期命中 | 0.26 / 0.28 ms | 0.28 / 0.36 ms | 0.33 / 0.35 ms |
| 中文 `你好`，早期命中 | 0.54 / 0.60 ms | 0.56 / 0.58 ms | 0.58 / 0.59 ms |
| 中文不存在的词 | 0.28 / 0.29 ms | 2.43 / 2.50 ms | 29.70 / 30.32 ms |
| 英文不存在的词 | 0.31 / 0.33 ms | 2.13 / 2.22 ms | 26.17 / 26.49 ms |

高频词用 limit 129 穷尽所有游标页，1k 为 17.06 ms、8 页，10k 为 1,282.34 ms、78 页。100k 高频首屏成本明显增长；中文/子串早期命中很快，不代表它们的零命中或尾部命中也保持固定耗时。唯一词比已有 scale test 的直接 FTS 查询多了生产 terms 路径的子串 fallback 成本。

### 实际 Release Runtime

10,000 条文本通过公开 ClipboardStore/SearchStore API 初始化，再由核验过身份的独立 Release E2E 程序调用生产 `runtime.history`。以下数据测量查询本身，排除控制 socket 开销，不含 Dock 绘制；常规查询 21 个样本，慢查询 7 个样本，均另外预热 1 次。

| 查询，limit 50 | 返回条数 | P50 | P95 / 最大值 | 样本数 |
|---|---:|---:|---:|---:|
| `common` | 50 | 16.61 ms | 16.86 / 17.11 ms | 21 |
| `uniquemarker9999` | 1 | 3.47 ms | 4.81 / 4.85 ms | 21 |
| `common type:text` | 50 | 18.88 ms | 20.45 / 20.98 ms | 21 |
| `common type:image` | 0 | 3,276.20 ms | 3,290.91 / 3,290.91 ms | 7 |
| `common app:com.review.missing` | 0 | 3,284.89 ms | 3,288.40 / 3,288.40 ms | 7 |

Dock 实际分页大小 16 的追加复测：5 次正式样本范围 **9,320.10–9,376.02 ms**，中位 **9,354.99 ms**，返回 0；语料是上述文本加 25 条不含 `common` 的合成内容。测试控制入口在主线程调用 history，但生产 Dock 在后台加载，所以不能用该入口的线程位置推导 shipping 主线程冻结。

### 自然采集与空闲资源

测试程序隐藏运行，使用自己的具名剪贴板，没有 `forcePoll`：文本、HTML、RTF、图片和文件各 5 次，共 25 次全部采集且原始载荷 SHA/解密读回一致。每种格式只有 5 个样本，不给可靠的格式 P95。

| 格式 | 中位采集等待 | 最大采集等待 |
|---|---:|---:|
| 文本 | 43.22 ms | 45.92 ms |
| HTML | 48.62 ms | 274.53 ms |
| RTF | 24.56 ms | 46.23 ms |
| 图片 | 23.66 ms | 46.42 ms |
| 文件 | 24.21 ms | 46.50 ms |

等待包含测试请求、自然观察轮询、落盘、索引及验证。输入很小，图片为微型 fixture；这些数字不能代表真实大截图 OCR 或所有 App 的剪贴板 provider。隐藏 E2E 的活动策略也不能直接等同于 shipping 后台 400 ms 的策略。

之后每秒采样一次、连续 60 秒，共 61 个样本：RSS 从 119.97 MiB 至 126.19 MiB，最大 126.59 MiB；`ps` 瞬时 CPU 百分比中位 0.0%。末次采集/OCR 队列深度与字节数为 0，采集未保存数、持久化失败数、过载数都为 0。WAL 约 1.94 MB（clipboard）、0.87 MB（search）；maintenanceQueueDepth 不可测，不把它当作零。短时 RSS 小幅上涨不能直接判定泄漏或长期稳定。

测试实例已通过核验 root/run/PID 的控制通道退出。证据：`natural-capture-results.json`、`idle-60s-samples.json`、`runtime-benchmark.jsonl`。

## 现有架构的优点与待验证边界

| 子系统 | 已有保护/验证 | 仍需关注的边界 |
|---|---|---|
| 采集及原生异常 | ObjC 异常桥转为 Swift 错误；代次校验、自己的写入 sentinel；最多 8 个 admitted jobs / 256 MiB 估算预算；过载有未保存与恢复计数 | 系统 Data provider 返回前的内存分配无法由接收后的字节阈值限制；单个 provider 调用的阻塞仍是原生 API 边界；FR-02 |
| OCR/图片 | 2 个并发识别、8 个 pending jobs / 64 MiB 来源预算；2048 像素降采样；空闲/低电量调度；生命周期 token 保护提交 | 预算不等于进程总 RSS；未测真实大图、Vision 工作内存和恢复后 OCR 的长时资源曲线 |
| Dock/预览/缩略图 | 后台请求与 cancellation/session identity；可见历史分页；缩略图 memory cache 和并发限制；恢复时缓存退役 | 16 条展示页与搜索候选扫描耦合；大集合下 Snippet/Pinboard 分类和图标等待队列的总量需压测 |
| Core 数据库 | WAL、busy timeout、schema/健康检查、加密 body 与 authenticated representation roster；附件引用重验证 | `storeLock` 串行共享，需测搜索/大 body 解密与同时采集之间的竞争；WAL 的 NORMAL 同步不能视为突然掉电时零数据损失 |
| 保留/删除 | 分页扫描、pin protection、跨 FTS/record/blob 删除 journal、附件租约和恢复重放 | FR-04；hourly/startup/settings 触发是软上限治理，不是每次写入后即时绝对硬盘上限；cap 不覆盖全部 DB/WAL/索引开销及受保护集合 |
| 备份/恢复 | SQLite 固定只读 snapshot、blob 根租约、manifest/密钥验证、阶段目录及回滚事务；实际 crash-child 回归覆盖恢复边界 | Keychain 的 device-only 密钥不随目录备份导出；密钥丢失/换设备的可恢复性不能等同于同机恢复；长期大量写入与慢备份下的 WAL 增长尚未测 |
| 启动/升级 | 恢复残留检测、启动失败处理、异步维护和 typed errors | `@MainActor start` 同步创建 Runtime，打开/迁移四个 DB 并载入 Snippet snapshot；migration 012 重建 representations 表。大历史升级、慢盘和接近 512×1 MiB Snippet 的冷启动尾延迟未测 |
| 隐私/权限 | 默认过滤 concealed/transient/password apps，显式 Capture All；Keychain AES-GCM；不具备数据上传路径；权限功能有降级 | preview/OCR/label/FTS content 可在本地 SQLite 中明文存在，不能称整个库端到端加密；建议 storage 目录 0700 / 数据文件 0600 和明确文案；未证明当前实际目录对其他用户可读 |
| CLI/集成 | 共用 request/exposure policy，默认只暴露 non-concealed pinboard；解析/策略有测试 | 当前独立 CLI 对 live search/get/pin/save 返回 unattached 状态，不能把帮助文本、MCP tools 清单当作可运行的完整 transport 服务 |
| CI/发布 | 固定工具及 SHA、生成工程检查、lint fixture、scale/stress/TSan、签名选择/路径/版本/发布 gate 等测试 | FR-01/05；本轮没有创建签名 DMG、notarize 或执行发布；现有 macos-26 CI 不覆盖当前 27 的全部诊断变化 |

静态扫描计数为 58 处 `@unchecked Sendable`、15 处 `.sync`、7 处 `fatalError`、1 处 `try!`，无 `as!`。这不是缺陷计数：coder initializer 的 fatalError 和常量正则的 try! 不应机械列为用户 crash；unchecked 类型应逐个对应锁/队列契约并由 TSan 和交错测试支撑。当前源码扫描未找到 URLSession/NWConnection/URLRequest，仅能支撑代码路径观察，不能替代完整二进制网络审计。

设置已经有 storage dashboard 显示条数/容量，不能说上限完全隐藏。`Unlimited` 实际指不按年龄淘汰，仍受 unprotected item/payload cap 约束；建议在选择处补充这个含义。`On disk` 当前累计 databases 与 blobs 目录的文件大小，而总量清理主要按未保护载荷及共享 blob 计量，两者并非同一口径；应避免把载荷预算理解为整个目录硬上限。以上列为产品说明和后续测量项，不额外计入已复现 P1/P2。

旧 Generation 4/5 的 legacy roster 维护、ImageCap 的共享附件回收、clean/staged lint gate 三项已有对应修复；本轮完整测试包含 legacy roster 和 ImageCap 的当前回归，不将它们重复列为开放缺陷。旧评审的 sanitizer host failure 也不能自动套用于这次工具链，当前完整 Package TSan 已独立通过。

## 竞品比较

以下是截至本次访问的官方能力与公开工程证据，关注它们怎样处理资源和可靠性。闭源产品没有公开的 crash rate 或同口径 P95；未公布容量/算法不能推断不存在上限。

| 竞品 | 官方/公开证据 | 对性能与稳定性的启示 | MacClippy 的定位影响 |
|---|---|---|---|
| Paste | 内容/来源/类型/日期/设备筛选，图片 OCR 搜索和高亮；Pinboards；age retention；私有 iCloud 可同步/迁移。[搜索](https://pasteapp.io/help/search-and-filters)、[保留](https://pasteapp.io/help/control-history-retention)、[备份迁移](https://pasteapp.io/help/where-paste-stores-your-data) | 用户会自然组合高频词与来源/类型，因此 FR-03 是核心交互场景；需要解释“永久”、受保护项目及恢复能力 | MacClippy 本地内容工作流有重叠，跨设备迁移能力存在差距；不能凭“instant”文案判断 Paste 更快 |
| PastePal | 原生 AppKit/Swift；边缘栏、collections、分页、OCR、queue/paste stack，买断和 iCloud；网页明确说分页用于性能。[产品页](https://indiegoodies.com/pastepal)、[队列](https://docs.indiegoodies.com/pastepal/Mac/features/queue) | 组合整理和粘贴栈是直接竞争场景；分页本身不保证查询快，需检查一页背后的全部工作 | 是 MacClippy 最直接的形态/功能参照；其“fast/unlimited”不是量化 benchmark |
| Maccy | 公开 Swift 项目；README 可配置 polling，默认 500 ms；2.7.0 说明缓存解码图片、减少整库 fetch、NSTextView 和异步视图；2.7.1 修复预览关闭冻结及满容量 pin crash。[README](https://github.com/p0deje/Maccy)、[发布说明](https://github.com/p0deje/Maccy/releases) | 维护者正在解决同类 AppKit、Unicode、预览生命周期和容量边缘问题；轻量键盘体验应以打开/搜索/退出的尾延迟衡量 | MacClippy 功能更多，也有更大的状态和资源表面；不能从 polling 频率或源代码行数判定整体更快 |
| CopyQ | v16.0.0 引入每 MIME 大小限制与 OOM 保护；FAQ 说明大数据分文件按需读、未用 tab 卸载，以及 stats；默认未启用加密时明文存储。[发布](https://github.com/hluk/CopyQ/releases/tag/v16.0.0)、[资源 FAQ](https://copyq.readthedocs.io/en/stable/faq.html)、[安全说明](https://copyq.readthedocs.io/en/stable/security.html) | 输入大小、驻留 payload、磁盘存储与 inactive collection 是不同预算；应该提供像 stats 一样可解释的资源诊断 | MacClippy 的加密 body、backpressure 和多格式保留有基础；可借鉴 MIME 级预算与集合驻留管理；不需要照搬全部脚本复杂度 |
| Clipy | 当前公开 release 页面为 1.3.0，恢复更新，支持 Apple Silicon；Realm→SQLiteData，明确告知迁移可能失败并建议先导出 snippets。[发布说明](https://github.com/Clipy/Clipy/releases) | “开源、轻量”不保证升级零风险；使用真实旧库和中途进程死亡验证升级/恢复有价值 | 不能沿用“Clipy 已停止维护”的旧判断；MacClippy 更复杂的数据结构需要更强的升级证据 |
| Raycast | 当前手册有原格式保留、多文件分组、rename/pin、QR/OCR、顺序粘贴；OCR fast/accurate 明确权衡 CPU；更长 retention 属于 Pro 设置。[Clipboard 手册](https://manual.raycast.com/clipboard-history) | 搜索加 action 的交互已成熟；OCR 可解释的速度/准确率选择、批次中断与数据格式保真是最低质量要求 | 用户已有 launcher 时新增独立产品需要明显工作流价值；MacClippy 的栏式可视整理可形成差异，基础 OCR/格式保留不足以独占 |
| Alfred | Powerpack clipboard/snippets；默认因隐私关闭捕获；age retention、合并剪贴板、最大 clip size、忽略应用和 concealed。[官方帮助](https://www.alfredapp.com/help/features/clipboard/) | 产品可通过输入阈值和明确保留时间减少膨胀；隐私配置的默认行为应可解释并可回归 | Snippet 与快速查找已是成熟能力，MacClippy 应在可视队列、多格式预览和恢复可靠性上证明价值 |
| Apple Spotlight | Apple 当前 Mac 使用指南支持 Spotlight Clipboard history、搜索、重新复制、清空；文档说明首次允许时可能出现敏感信息。[Apple 支持](https://support.apple.com/en-hk/guide/mac-help/mchl40d5b86b/mac) | 基本历史搜索已有系统入口；独立产品不能只依靠“能找回复制内容” | 需要持续组织、复杂格式/队列、过滤和备份工作流来超越系统基础体验；这里不声称官方未说明的历史时长或容量 |

本轮的战略判断是：**以本地多格式整理、可视粘贴队列和可验证的数据恢复作为主轴**。保持轻量闲置资源和高频搜索尾延迟，先消除已有核心路径问题，再投入同步或更多外部集成。该判断是基于产品能力与代码/测试结果的推论，不是用户转化或市场份额统计。

若需要速度排名，后续必须用同机、同 OS、相同 retention、相同格式/文本长度、相同语料和相同预热规则测各产品。优先覆盖 1k/10k/100k、中文/英文/emoji、唯一词/高频词/零命中筛选、打开面板、首屏显示、滚动预览、大截图 OCR、连续复制、退出/重启以及资源回落；记录 p50/p95/p99、RSS、实际 CPU 时间和入库成功率。

## 测试门禁与未验证事项

| 检查 | 本轮结果 | 说明/证据 |
|---|---|---|
| 常规完整 Package | PASS：689 executed，4 skipped，0 failures | Platform 324、Core 365；`package-tests.log` |
| 完整 Package TSan | PASS：689 executed，4 skipped，0 failures；0 sanitizer race 报告 | `package-tsan.log`；含默认运行的 crash-child 恢复用例，跳过独立 worker 和 opt-in 规模/压力 |
| 正常 App Debug 测试构建 | FAIL：exit 65，未运行测试 | FR-01；`app-tests.log` / `app-tests.xcresult` |
| App 诊断单测 | PASS：422 executed，2 skipped，0 failures | 命令行关闭 warnings-as-errors；跳过 Runtime scale 与真实输入 event tap；`app-tests-diagnostic.log` / `.xcresult` |
| 严格并发 + scale/stress Package | PASS：689 executed，1 skipped，0 failures；无编译 warning | `package-strict-scale-stress.log`；100k/20 MiB 两项共 43.13 秒；10k 生命周期循环 0.73 秒 |
| App 诊断 TSan + Runtime scale | PASS：422 executed，1 skipped，0 failures；0 sanitizer race 报告 | `app-tsan-diagnostic.log` / `.xcresult`；Runtime 10k fixture 14.07 秒；命令行关闭 warnings-as-errors |
| Core CLI Release 构建 | PASS | `core-release-build.log` |
| 独立 Release E2E 构建 | PASS，仅诊断配置 | 关闭 warnings-as-errors；`e2e-release-build.log`；不能替代 shipping Release 门禁 |
| 固定版本 SwiftLint | FAIL，完整扫描 471 文件，4 violations | `lint-confirmed.log`、`lint-full.log` |
| lint 门禁 fixture | PASS：5 tests | `lint-gate-tests-confirmed.log` |
| E2E runner unit suite | PASS：37 tests | `e2e-runner-tests-confirmed.log` |
| 构建/发布脚本 fixture | PASS：10 个脚本套件 | `script-fixtures.json`；发布/tag/签名操作在测试中 mock，未实际发布 |
| Release 自然采集 | PASS：25/25，5 种格式，原始 payload round-trip 一致 | `natural-capture-results.json` |
| Git diff whitespace | PASS | `git diff --check`；不是对用户已有改动的审批 |

常规 Package+App 合计 1,111 个测试条目，6 个跳过，0 个执行失败；App 结果属于诊断配置。重跑、TSan、opt-in 的执行次数不能再累计为不同的新增测试数量。

启用 opt-in 后，相同的 1,111 个条目只剩 2 项跳过：Package 的私有 child-only worker 入口及 App 的真实输入 event tap。Package strict/scale/stress 与 App TSan 都已完成，不能据此覆盖正常构建失败。App 测试日志还出现系统 `com.apple.linkd.autoShortcut` 服务连接等环境消息，XCTest 与 sanitizer 没有因此失败；不把这些日志机械算作产品 crash。

最终文件摘要复核显示原有产品源码和 HEAD 未改变；新增长期文档仅本报告。Python 单测刷新了已有的 `scripts/e2e/__pycache__/test_macclippy_phase5.cpython-314.pyc` 生成缓存。原始复核记录为 `preservation-check.json`。

尚未验证：macOS 14 最低版本实机；Intel/x86_64 运行时；真实 Safari/Chrome/Office/IDE/密码管理器/远程剪贴板互操作；真实权限 UI 和 Input Monitoring event tap；shipping 可见 UI 的首次打开/热打开/滚动帧率；100k 混合历史可见 UI；大型/畸形图片与真实 OCR 吞吐；旧库升级冷启动；磁盘满/慢盘/系统掉电；24h/72h soak；竞品同机 benchmark；实际签名/notarization/DMG 安装卸载。

这些是证据缺口，不能默认记作代码缺陷，也不能记作 PASS。Package 规模 fixture 的 3 秒搜索阈值与 Runtime fixture 的 30 秒阈值用于粗粒度回归，对即时搜索体验过宽；匹配词/空结果/组合筛选的可见结果延迟还需要独立 gate。

## 修复顺序与验收

1. **先恢复构建并约束隐私匹配**：修 FR-01/02，同时保持严格门禁；短文本恶性正则应在预算内安全拒绝，后续采集仍能推进。
2. **解决搜索候选路径**：修 FR-03，建立默认容量下高频词 × 低命中筛选的回归，并验证中文/infix、游标稳定性和请求取消；记录真实 Dock 首次可见结果耗时。
3. **统一容量回收口径并清理门禁**：修 FR-04/05，实际回收而非预计回收应决定清理是否结束，按职责拆分超长实现。
4. **补长期与平台证据**：真实 App paste/权限、macOS 14/Intel、历史库升级、慢盘/磁盘满、大图与 OCR、24h/72h 资源曲线。保留 source/build 摘要及原始结果，确保一次测试明确对应一个版本。
5. **之后做功能投入决策**：根据目标用户决定是否开发安全可迁移备份、跨设备能力或真实 CLI/MCP transport；先与 PastePal/Maccy/Raycast 的关键场景做同机 benchmark。

以上是后续工程建议，本轮未实施源码修复、创建 commit/PR、推送或发布。


## 修复与复测追加（2026-10-01）

用户随后授权 patch。本节对应修复后的工作区，原始评审和竞品证据保持不变；已有用户改动得到保留，未创建 commit/PR、推送或发布。

### 五项修复

| 问题 | 修复 | 验证 |
|---|---|---|
| FR-01 | 外层异步任务显式弱捕获 `self`；选择栏只捕获 `onClose`，删除无效的 `weak model` 捕获 | App Debug 测试、Shipping/E2E Release 构建均保持 warnings-as-errors 并通过 |
| FR-02 | 规则初始化或更新时缓存编译结果；用 ICU/Foundation `.reportProgress` 回调停止实际匹配；整组规则共享 20 ms 合作式预算，失效或超限时阻止采集 | 29、33、1,001 字符的灾难性回溯输入均约 20 ms 返回；普通/Unicode/多行规则、修改与值拷贝测试通过 |
| FR-03 | 先以元数据筛选 ID；用连接内临时表限制 FTS 命中集；按 `record_id` 过滤以保留单次 MATCH 扫描；候选批次下限 128，与 Dock 的 16 条返回页分开 | 10k 高频词、高命中/单命中/空结果均通过 Release P95 ≤100 ms gate；中文、短词 infix、短语、分页、revision、取消、Unicode 来源/标签与旧来源名称回退有回归覆盖 |
| FR-04 | 只依据删除结果的 `reclaimedBlobIDs` 扣除附件字节；完成删除扫描后重新核算载荷和共享引用，处理并发新增所有者及 inline 载荷 | 原复现上限 4,257 bytes，最终载荷同为 4,257 bytes；新所有者与共享 blob 保留，另一附件删除，提交 2 次 |
| FR-05 | 按职责拆分卡片拖拽和 Runtime 拖拽导出；提取表示读取、结构化命中投影及 SQL 解析辅助函数；更新工程来源清单 | 固定 SwiftLint 0.63.2 的 changed-file 与全库 strict gate 通过：480 个 Swift 文件、0 violations；baseline 未扩充 |

主要实现位置为 [有预算的正则匹配器](../../MacClippyKit/Sources/MacClippyCore/MacClippyBoundedRegexMatcher.swift)、[Runtime 搜索筛选](../../MacClippy/MacClippyRuntime+SearchScope.swift)、[FTS 查询](../../MacClippyKit/Sources/MacClippyCore/SearchStore+Terms.swift)、[临时筛选表](../../MacClippyKit/Sources/MacClippyCore/SearchStore+Scope.swift) 和 [总载荷清理](../../MacClippyKit/Sources/MacClippyCore/RetentionPolicy+TotalCap.swift)。另外将 Core 数据库健康测试钩子的受锁保护可变状态封装进不可变共享引用，消除这两处完整并发检查的静态状态诊断。

正则资源策略：最多 128 条、每条最多 8 KiB UTF-8；启用规则时，超过 1 MiB UTF-8 的文本按超限处理并阻止采集。无规则时仍允许正常采集。20 ms 是可取消回调预算，并非操作系统级硬实时保证；本机恶性输入的最大样本为 20.13 ms。预算耗尽相当于隐私规则拦截，不会让后台 matcher 继续无限运行。

### Release 性能复测

复用原评审的独立 E2E 根目录：10,000 条含 `common` 的合成文本及此前 25 条其他合成剪贴记录。仍为同一 M4 Max/macOS 27.0.1；使用 Release、真实 Runtime `search-db` 路径，每类查询预热一次并记录 21 次正式样本。测量时没有同时运行构建或测试；验证了运行进程路径、E2E bundle identity 和 source-content digest，结束后通过该实例的 root-scoped terminate 命令关闭。

| 查询 | limit | 命中条数 | P50 ms | P95 ms |
|---|---:|---:|---:|---:|
| `common` | 50 | 50 | 16.46 | 16.74 |
| `uniquemarker9999` | 50 | 1 | 2.52 | 2.76 |
| `common type:text` | 50 | 50 | 50.42 | 53.23 |
| `uniquemarker9999 type:text` | 16 | 1 | 31.27 | 31.99 |
| `common type:image` | 50 | 0 | 9.37 | 9.62 |
| `common app:com.review.missing` | 50 | 0 | 29.39 | 29.86 |
| `common type:text` | 16 | 16 | 48.16 | 48.81 |
| `common type:image` | 16 | 0 | 9.42 | 9.55 |
| `common app:com.review.missing` | 16 | 0 | 29.85 | 30.73 |

最初的 `common type:image`、limit=16 中位耗时为 **9,354.99 ms**，修复后为 **9.42 ms**。空结果类型查询约 9.55 ms P95；来源空结果约 30.73 ms P95。单命中组合查询约 31.99 ms P95。

高命中率组合查询付出了筛选表准备成本：limit=50 的 `common type:text` 从原来的 20.45 ms P95 增至 53.23 ms，仍满足本轮 100 ms 目标。裸词 `common` 维持约 16.74 ms P95。临时筛选表不改持久搜索索引和 revision；其内存及准备成本与符合元数据条件的 ID 数量成正比。这组结果不是 100k 历史、冷启动或可见 UI 帧率承诺。

初版 `rowid IN` 筛选被 Release 实测否决：SQLite 使用 `=M3` 路径，导致高命中率查询逐行重启 MATCH；已改成 `record_id IN` 并加入默认运行的 10k 高频词 FTS 回归。保留排序与游标语义，没有通过删除 rowid 排序来获得这些数字。

### 测试与证据

- 完整 Package TSan + strict concurrency：**700 项，4 项跳过，0 失败，无数据竞争报告**（Platform 324 / Core 376）。本轮也完成了修复阶段的 scale/stress 完整检查：699 项，1 项跳过；后续新增的第 700 项为默认 10k 高频词筛选回归，在普通与 TSan 模式均通过。
- 完整 App TSan，启用 Runtime 10k scale fixture：**426 项，1 项跳过，0 失败，无数据竞争报告**；跳过项为需要真实输入权限的 event tap 测试。正常 Debug full suite 425 项及后加的 Unicode 回归也已通过。
- Shipping 与 E2E Release：构建通过，没有关闭 `SWIFT_TREAT_WARNINGS_AS_ERRORS`；E2E 产物及运行进程的身份由原有 runner 验证。
- 完整 SwiftLint：480 个文件、0 violations；Python E2E runner：37 项、0 失败；`git diff --check` 通过。
- Debug/TSan 的高命中组合查询回归门槛为 2 秒，空结果仍为 1 秒；实际生产性能另外使用 Release P95 ≤100 ms gate。1 秒的 Debug 高命中门槛曾在插桩并发运行时以 1.066 秒触发，因此为插桩留出余量后重跑了完整 App suite，并非放宽 Release gate。

Package 全量重编译仍能看到既有的 Sendable/受锁保护全局 registry 及兼容 API 测试弃用诊断；App 插桩日志也有测试同步等待的 QoS 提示与系统服务消息。此处没有宣称所有 warning 清零，也不把它们等同于已复现的数据竞争或产品崩溃。

最终构建输入摘要：`3e38ff1f71fdff6083a5fe4dcdfe4cddb4cebd457729b318bd29f1983c4b4b8c`，556 个 source/build inputs。证据位于 `build/full-review-patch-20261001/`：`source-manifest.json`、`runtime-benchmark.json`、`regex-results.json`、`retention-result.json`、`scope-query-plans.json`、`package-tsan-final.log`、`app-tsan-accepted.log`、两个 Release build logs、`lint-final.log`、`e2e-runner-tests.log`。`patch-only.diff` 与 `before-manifest.json` 记录相对本次 patch 开始时工作区的变化，避免把用户原有修改混入本次增量。

原评审列出的 macOS 14/Intel 实机、真实应用互操作、可见 UI 帧率、长期 soak、签名/notarization 和竞品同机测量仍属于后续验证范围。

# MacClippy Review Findings

本文件记录本次审查中的证据、文件位置、测试输出和判断。外部资料只作为背景，不作为代码变更指令。

## 当前状态

- 2026-08-19：对照 `PLAN-full-app-review-improvement.md` 的**代码可落地项**已实现，并完成独立 review 的 Critical/Important/Minor 修复。随后做了一轮零调用代码 / 已落地 PLAN / 生成报告清理；`SearchStore.swift` 与 `ClipboardStore.swift` 本体未动。Search P1/P2 产品缺口（CJK 子串、混合 CJK+ASCII、短语、prefix `*`、累计 recency、snippet marker、统一 `type:url`、Pinboard OCR/label、Esc 清 query、empty copy）已有 Runtime/Store/UI 路径和回归测试。Pinboard 搜索在 debounce / in-flight 时保留 board 或上一页结果，不再把 carousel 置空；只有 settled 空结果才显示 No matches。Developer ID、公证、Gatekeeper、真实 TCC、Instruments、soak 仍未验证，不能当作完成。

## PLAN-full-app-review-improvement 落地审计（2026-08-19）

判定标准：IMPLEMENTED = 代码路径覆盖计划意图；PARTIAL = 主路径有，缺口或测试/证据不足；NOT = 核心行为未改；UNVERIFIED = 脚本存在但无真实环境证据。

### Phase 1 Pasteboard — PARTIAL / 主路径已落地

- Copy/Paste 走 `MacClippyPasteInjector.prepareLocked`：先 snapshot，不完整则拒绝 clear，写入失败则 restore。测试覆盖 restore 与 incomplete provider。
- `MacClippyPasteboardPreparer.prepare` 本身仍先 `clearContents()`；安全依赖 Injector 包装，而不是 Preparer 自己事务化。
- Copy API 仍返回 `Bool`。Dock `perform`/`performWithSideEffect` 把 `false` 转成 failure，不再当成功 toast。`MacClippyCopyAllTests` 覆盖 `prepare == false` 时不发成功 toast。
- 并发覆盖“其他 App 新剪贴板”的 change-count 校验主要在自动 Paste/sentinel 路径；普通 Copy 没有对外部写入的校验。Image/URL/多 representation 失败 restore 已有 Platform 测试。

### Phase 2 Search / Pagination — 主路径 IMPLEMENTED，仍有残留

- History Dock 使用 `historyPage` + FTS rank/rowid keyset + `indexRevision`；revision 变化抛 `searchIndexChanged`，UI 重启当前 query。
- Pinboard **搜索**已下沉 Runtime：`pinboardSearchPage` 用 boardModified + memberOffset，失败保留 continuation 与 pageError。
- Pinboard 无 query 的 item 分页失败会设置 `pageError`，carousel footer 走 `retryCurrentPage`。
- Search continuation token 含 indexRevision + lastRank/rowID，但不嵌入 query/sort；调用方必须自己保证后续页使用同一 query。
- 兼容 API `history(limit:query:)` 循环 `historyPage`。裸词走 `search(terms:)`（纯 CJK LIKE；ASCII FTS MATCH + CJK LIKE；短语 / prefix `*`）。History 累计页和 Cmd+A ID 按 recency 排序；分页 cursor 仍是 FTS rank/rowid。
- Pinboard 裸词匹配 preview + OCR + customLabel，并用无 10k 上限的 FTS ID 集补 body-only 命中；FTS 扫描在 store lock 外。
- 有 10k Runtime 与 100k Store 夹具；取消用 generation/token；page failure 可 retry。

### Phase 3 Error model — PARTIAL

- 已拆 `historyLoadError` / `pageError` / `previewError` / `actionError`；carousel 不全屏覆盖；分页 footer Retry。
- History/page/details 失败会通过 `MacClippyUserFacingError.message(for:)` 映射 storage/permission/corrupt/missing；Preview 仍多用通用 `itemLoad`（`showPreview` 函数体长度限制）。
- `searchIndexChanged` 仍调用 `reload()`，不是绑定原操作的 typed retry。

### Phase 4 Concurrency — PARTIAL

- History 分页：锁内有界 read，解密在锁外。
- Pinboard 搜索：先锁内取 board snapshot，FTS 在锁外，再锁内校验 `board.modified` 后扫 membership；`entries()` / 解密在锁外。
- OCR metadata 与 FTS upsert 在同一 lifecycle lock 内，但是两个 SQLite 库，不是同事务；失败写 repair marker。
- Retention 有 captureQueue snapshot + debounce；`Task.detached` / `@unchecked Sendable` 仍存在。

### Phase 5 Accessibility — PARTIAL

- Loading labels、Preview action、search announcement、NSWorkspace high contrast 已有。
- Dynamic Type 会升高 card/carousel 高度；SwiftUI `colorSchemeContrast` / `accessibilityDifferentiateWithoutColor` 已并入 `highContrast`；横向 scroll 仍隐藏 indicator，但有 edge fade。
- Search announcement 覆盖 History / Pinboard / Snippets；除 `isLoading` / tab 切换外，也会在 `pinboardSearchIsLoading` 结束和 `filteredSnippets` 变化时播报。仍报当前已加载数量而不是全集。

### Phase 6–9

- Signpost：preview、`search_keystroke`、`dock_open`、`card_scroll` 已有 UI 探针。File icon waiter cancellation 有测试。卡片仍观察整个 `ObservableObject`；未接线的 Equatable card scaffolding 已删除。无 Instruments 证据。Retention 读写仍跨 captureQueue / maintenanceQueue / Settings `@AppStorage`。CI 有到 Release compile + metadata；notarize/staple/Gatekeeper **不在** CI job 里。
- 架构拆分已做 façade + extension，大文件仍在。
- CI 步骤覆盖 package/strict/scale/stress/TSan/App build；本机 App XCTest 仍受 LaunchServices 阻塞。
- Phase 9 发布验证：Apple Development 本机签名 ≠ Developer ID / notarization / Gatekeeper。`EXPECTED_TEAM_ID` 已传入 `verify-dmg.sh`。

### Search 独立复审（2026-08-19 实现后）

1. CJK 走现有 `content` 列的 LIKE 子串搜索，不新增 FTS trigram / schema。
2. `search(terms:)` 用 `ftsMatchQuery` 保留短语和 `clip*` prefix，不再被 `ftsQuery` 二次拆词。
3. History 搜索累计页和 Cmd+A 按 recency 展示；分页 cursor 仍是 FTS rank/rowid。
4. 卡片 preview 去掉 FTS `\u{001E}`/`\u{001F}` 以及兼容的 `<term>`；HTML 属性标签会保留。重叠 highlight range 会合并。
5. 有 query 时 empty copy 为 No matches；冲突 `type:text type:image` 和 `type:url type:image` 显示 Incompatible type filters。
6. 第一次 Esc 清空 query，第二次退出 search。
7. `type:url` 解析为 `.url`。SQL 预过滤 `detected_type` 含 url 或 `http(s)://` 前缀；内存判定是 JSON 含 url 或 `MacClippySmartText.matchesURL`。`www.` 和 `http status 500` 不再当 URL。
8. 文件索引只写 `lastPathComponent`。
9. Pinboard `visibleItems` 在 debounce / loading / query 未对齐时回退 board 或上一页结果；settled 空搜索才显示 No matches。
10. 兼容 `SearchStore.search(query:)` 仍走旧 `ftsQuery` 拆词，未改 `SearchStore.swift`（lint）。

## 基线观察

- Worktree 非常 dirty：既有 App、Core/Platform、测试、CI、项目生成文件和发布脚本的用户改动；本次 review 不应把这些改动误判为本次新增。
- 当前代码约 25,000 行；最大单文件包括 `MacClippyRuntime.swift`（867 行）、`MacClippyDockCard.swift`（769 行）、`ClipboardStore.swift`（603 行）、`MacClippyDockController+Lifecycle.swift`（533 行）和 `MacClippyRuntime+History.swift`（533 行）。虽然已做 extension 拆分，但仍存在高复杂度文件。
- `project.yml` 使用 Swift 5.9、完整严格并发检查和 macOS 14 deployment target；Release 开启 hardened runtime 和 dead-code stripping，Debug 明确关闭代码签名。
- App 依赖 `MacClippyCore` 和 `MacClippyPlatform`；当前 Package 依赖只有 GRDB.swift。未发现 Sparkle/appcast/updater 接入。
- CI 已包含 package tests、严格并发 package tests、scale、lifecycle stress、TSan、App TSan、Debug/Release compile、metadata verifier 和 App XCTest steps；真实 Developer ID、notarization、TCC、Gatekeeper、Instruments/soak 仍需单独证据。
- 初步高风险模式仍存在：`Task.detached`、`@unchecked Sendable`、semaphore wait、CGEvent tap、多个 `try?`，以及 AppKit lifecycle 中大量 `DispatchQueue.main.async`。这些不等于 bug，需要结合所有权和取消语义逐处确认。

## 记录问题

- 本次 review 启动时误将已有的 planning 文件内容替换成新的 review 记录；已停止继续覆盖代码，但原有未提交的 `task_plan.md`、`findings.md`、`progress.md` 内容需要在后续恢复/合并，不能在最终结果中假装它们未受影响。

## 生命周期与并发初步证据

- `MacClippyRuntime+OCR.swift` 已有 generation token、active/pending budget 和停止时取消队列，旧 generation 在 OCR 开始及写库前会被检查；这部分符合当前目标，仍需确认所有后台写路径都经过同一 lifecycle fence。
- `MacClippyRuntime+Lifecycle.swift` 的 `start/stop` 由 lifecycle lock 串行化，并在 stop 时停止 observer、Snippet、取消 OCR；这是正面实现，但需要继续核对 lock 与 store lock 的顺序，避免长时间搜索/解密阻塞 stop 或 capture。
- `MacClippyRuntime+HistoryPagination.swift:6-11,229-276` 对 FTS page token 使用 `searchOffset(Int)`。FTS 查询按 rank/rowid 排序时，捕获、OCR 或 label 更新可能改变索引内容或排序，继续加载时存在漏项/重复项风险；应改为稳定 ID snapshot 或带 search-index revision 的 token。
- `MacClippyRuntime+HistoryPagination.swift:45-53` 将整次分页、metadata 读取、解密和 DTO 构造包在 `withStoreLock` 中；大数据或损坏记录时会扩大 capture/paste/edit 的等待时间。建议锁内只生成有界 snapshot，解密和 DTO 构造移到锁外，并用版本校验/短页锁保证一致性。
- `MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardPreparation.swift:18-33` 先清空 pasteboard，再执行字符串/data/object 写入；普通 Copy 路径没有像自动 Paste 那样的完整 snapshot/restore。任一步写入失败都可能清空用户原剪贴板，属于数据丢失风险，建议 P1 修复。
- `MacClippy/MacClippyRuntime+ClipboardActions.swift:47-51` 的 Copy API 返回 `Bool`，但 `MacClippyDockModel+Utilities.swift:144-161` 的成功包装只判断 `Result.success`，因此 `false` 仍会触发成功 toast；需要把 `false` 转为 typed failure 或改为非布尔结果。
- `MacClippyRuntime+OCR.swift:198-232` 先写 OCR metadata、再更新 FTS projection；崩溃窗口可能留下 metadata 已更新但索引旧的状态。当前有 repair marker/diagnostics，但不是同一数据库事务；建议持久化 pending projection 或让 source 与 projection 同事务提交。
- `MacClippyRuntime.swift:382,443` 与 `MacClippyRuntime+Lifecycle.swift:55-58,74` 对 retention preferences 的访问跨 capture/maintenance/observer 队列，未见独立 actor/lock；存在数据竞争风险，建议收敛到一个 serial owner 或 actor。
- `MacClippyRuntime+History.swift:374-380` 初次只为每个 pinboard 解密并加载 64 条；`MacClippyDockModel+Selection.swift:22-44` 只有当“当前可见列表的最后一条”出现时才继续加载。`visibleItems` 在 `MacClippyDockModel+LoadingPreview.swift:36-38` 对已加载数组做本地过滤，因此搜索 query 会漏掉尚未加载但匹配的 board item，且分页失败没有用户可见错误。Pinboard query 需要服务端/Runtime 级分页搜索或在搜索时逐页扫描至结束，并保存 query-specific continuation/error state。
- `MacClippyFileIconLoader.swift:46-56,100-156` 共享 in-flight producer，但调用方取消只在拿到 `request.task.value` 后检查，未维护 waiter count，也没有在最后一个 waiter 离开时取消 producer；快速横向滚动离屏后，`NSWorkspace` 图标解析仍可能继续运行。属于 P3 性能/能耗优化，建议加入 waiter cancellation 和 producer cancellation。
- `MacClippyKit/Sources/MacClippyCore/ClipboardStore+BlobReferences.swift:47-69,101-119` 维护扫描仍用 `LIMIT/OFFSET` 逐页遍历；记录增删时 offset 可能跳过或重复扫描，且大历史下 offset 成本逐步上升。建议改 keyset cursor，或使用稳定快照/最终 fenced re-check。
- `scripts/notarize.sh:31-33` DMG 分支调用 `verify-dmg.sh` 时没有传递已读取的 `EXPECTED_TEAM_ID`；而 `scripts/verify-dmg.sh:11-13` 明确要求该变量。notarize/staple 成功后 DMG 验证会直接失败，属于 P1 release blocker。

## Dock / Settings / Motion / Accessibility 证据

- `MacClippyDockView+CarouselModal.swift:119-132` 只要 `model.errorMessage != nil` 就用全屏错误状态覆盖已有 carousel；但 `MacClippyDockModel+LoadingPreview.swift:196-200` 的注释和行为意图是保留 last successful snapshot。Action/preview/label/pagination 失败都可能共用这个 `errorMessage`，而 Retry 固定调用 `model.reload()`，无法重试原 Copy/Paste/Delete/Pin/Transform 操作。建议拆分 `historyLoadError`、`actionError`、`previewError`、`pageError`，保留内容并让 Retry 与失败操作绑定。
- `MacClippyDockModel+HistoryPagination.swift:107-113` 分页失败时已有 items 会设置 `historyHasMore = false` 且不显示错误；用户会看到列表悄悄停止增长。应保留 continuation、设置 page error，并在 carousel 尾部显示可重试 footer。
- `MacClippyDockModel+Selection.swift:22-57` Pinboard 分页失败会静默 return；没有 page error、retry 或“仍有更多”状态，和搜索漏项叠加后难以判断数据是否完整。
- `MacClippyDockPolicies.swift:130-152`、`MacClippyDockCard.swift:164-186,194`、`MacClippyDockPreviewSupport.swift:110-121` 使用固定卡片尺寸和固定 11/12/13pt 字体；`MacClippySettings+Sections.swift:44,102,127` 也有固定控件宽度。大字号/字体辅助设置下可能截断标题、卡片正文、按钮或横向溢出。建议用 Dynamic Type-aware fonts、可伸缩高度/文本布局和最小宽度约束。
- `MacClippyDockView+FilterDrop.swift:10`、`MacClippyDockView+HeaderSearch.swift:59`、`MacClippyDockView+CarouselModal.swift:150,190` 隐藏全部横向 scroll indicators。对键盘/VoiceOver 之外的普通用户，更多 pinboard、card 和 selection actions 不可发现；建议保留 indicator 或提供 edge fade/左右导航提示。
- 当前未发现 `accessibilityContrast` 或 `differentiateWithoutColor` 分支；`MacClippyDockTheme.swift:16-37,44-47` 及多处 alpha border/accent 使用自定义低对比度颜色。High Contrast、彩色 accent 和深色模式组合仍需真实 VoiceOver/高对比度验证，建议增加 contrast-aware token 分支，并保证选中/Drop 状态不只靠颜色。
- `MacClippyDockView+CarouselModal.swift:114-118`、`MacClippyDockPreview.swift:211-214`、`MacClippyDockPreviewSupport.swift:42-46` 的 loading `ProgressView` 没有明确 accessibility label；VoiceOver 只能得到无语义的进度控件。建议分别标记 “Loading clipboard history / Loading preview / Loading image”。
- `MacClippyDockCard.swift:261-296` 给卡片提供 Copy/Paste/Delete/Label/Pin 等 accessibility actions，但没有显式 Preview action；仅依赖 Space/键盘路由对 VoiceOver 用户不够可发现。建议增加 Preview action 并在进入 preview 后明确焦点与返回路径。
- 卡片 VoiceOver label (`MacClippyDockCard.swift:375-404`) 有意不读完整正文，这保护隐私；但文本卡片只返回 type/source/time，多个相似记录难以区分。可增加截断、脱敏的 accessibility value 或明确“通过 Preview 读取内容”的 action，而不是把完整 clipboard body 放进 label。
- `MacClippyMotion.swift:4-111` 的时长和 transform/opacity 方向整体符合 native utility 目标，Reduce Motion 同时读取 SwiftUI/AppKit 来源且 transition 返回 identity；这是正面实现。仍缺少 Core Animation/Instruments/真实设备帧率证据，不能把代码检查当成 60fps 证明。

## Implementation 验证记录

- `xcodegen generate` 成功，重新生成工程后包含当前新增拆分文件。
- 修复 `MacClippyRuntime.swift` 缺失的 `macClippyRuntimePerformanceLog` 后，Debug arm64 macOS App build 成功。
- App build 仍输出 CoreSimulator 版本不匹配警告（当前 1051.54.0，Xcode 需要 1051.55.0）；这是环境限制，不是 App 编译错误。
- 当前不能把 Debug build、package tests 或 metadata verifier 作为签名、公证、TCC、VoiceOver、Instruments、soak 或 Gatekeeper 通过证明。

## Add Category follow-up（2026-08-10）

用户反馈的“点击经常没反应”由两个高概率因素叠加：顶部 `+` 和颜色圆点的实际命中区过小，以及 dock 使用 `nonactivatingPanel` 时 first-mouse 可能先被 AppKit 用于恢复 key window。实现已在 `MacClippyDockPanel.swift` 增加 hosting/content view 的 first-mouse 接收策略，并把操作控件的透明命中区统一到 40pt。

颜色改为稳定的 macOS Theme-inspired 值（blue/purple/pink/red/orange/yellow/green/graphite），没有改变已有 category 的存储格式；旧的自定义 HEX 仍可显示。modal 宽度调整为 460pt、内边距调整为 28pt，颜色行不再挤满内容区。选中态增加 checkmark、system accent ring、VoiceOver selected value 和 UI identifier。创建 category 的异步流程现在在成功前保持 modal，失败时显示可重试反馈，避免后台写入期间看起来像点击没有生效。

本轮新增 `MacClippyCoreUtilityTests.testCategoryPaletteUsesAppleInspiredSemanticNames`，并完成 lint、Package tests、Debug App build、metadata verifier 和 diff 检查。真实首次点击行为、VoiceOver、Light/Dark appearance 和高对比度仍需在本机 App 与 TCC 环境手动验证；当前 App XCTest 仍受既有 LaunchServices/CoreSimulator 环境限制。

## Resolution / validation summary

已落地并由当前测试覆盖的核心改动：

- Runtime OCR 使用 lifecycle generation/token；停止、重启和 queued cancellation 不会让旧 generation 写入新 Runtime。
- disabled Snippet 不安装 event tap；preference 动态切换、生命周期 stress 和平台策略测试通过。
- ClipboardStore 的 ID-based reads 使用 500 条分批查询；超过 SQLite 参数限制、顺序、重复和缺失 ID 测试通过。
- History/FTS/Pinboard pagination 已使用稳定 cursor/keyset；100,000-record scale fixture 通过。
- Runtime、Dock、Controller、Settings 和 ClipboardStore 已拆分为 façade + extension；Debug App build 和 strict concurrency package tests 通过。
- `MacClippyDockModel` 已显式 MainActor 隔离；输入、选择、outside click 和 pagination 相关回归测试通过。
- metadata verifier 已切换为验证运行时 activation policy 所需的 bundle 元数据，而不是强制静态 `LSUIElement=true`。

仍需真实设备/发布环境验证的项目：

- App XCTest 运行阶段：当前 LaunchServices worker 未 materialize，结果为 `TEST INTERRUPTED`。
- TCC permissions、VoiceOver、High Contrast、Reduce Motion 的真实系统交互。
- Core Animation/Allocations/Energy/Instruments、long soak 和真实用户数据下的 frame budget。
- Developer ID、Hardened Runtime signed artifact、notarization/staple、Gatekeeper 和 DMG signed verification。

## Preview OCR selection review（2026-08-10）

- Apple `ImageAnalysisInteraction` 当前没有原生 macOS availability；不能直接依赖 Apple Live Text UI。
- 当前图片 Preview 只有 SwiftUI `Image`，OCR service 只返回拼接字符串，没有 selection geometry。
- 当前 Dock keyboard routing 只查找单个选中的 `NSTextView`；每行一个透明 text view 不足以支持可靠的跨行 selection 和统一 `Cmd+C`。
- Preview panel 不是 key window，因此 OCR selection 必须由 Dock Controller 显式路由，不能只依赖 Preview first responder。
- 整行 bounding box 不足以精确选中中文、代码标点和混合文本；需要 character/text-range geometry，无法提供时必须明确降级为整行选择。
- Preview OCR 不应复用 Runtime 的持久化 OCR 写库生命周期；应绑定 Preview generation、RecordID 和 content fingerprint，并在关闭/导航时取消。
- 图片显示和 OCR 应共用一个 bounded `CGImage`；OCR cache 只保留轻量 layout DTO，避免从同一原始 Data 重复解码。
- 新的 OCR layout 和 selection 类型应保留在 Platform/App 边界，不扩散到 Core，也不默认暴露为 public API。
- 本次 review 没有修改业务代码；实施计划已写入 `PLAN-preview-image-text-selection.md`。

## Preview OCR selection implementation（2026-08-10）

- `MacClippyOCRService` 现在在 Vision observation 中保留稳定排序的 line/character geometry，并保留既有 `recognize(data:) -> String` API；字符 geometry 不完整时 selection view 通过整行 fallback 保证仍可复制。
- `MacClippyDockPreviewImage` 使用同一份 downsampled `CGImage` 绘制图片和执行 Preview-only OCR；图片 task 使用 `RecordID + Data fingerprint`，避免同一 RecordID 内容变化时复用旧 OCR。
- Preview layout cache 是独立 actor，最多 8 项、约 2MB layout cost，不保存图片 Data，也不进入 Runtime/Core 数据库。
- `MacClippyDockController+Input.swift` 保持 Dock keyboard ownership；`MacClippyOCRSelectionView` 只负责 mouse hit-testing/selection state，`⌘C` 由 Controller 调用 selection host；OCR selection copy 走现有 pasteboard sentinel 路径，避免 OCR 文本被重新捕获。
- 关闭 Preview 会把 hosting root 切换为轻量 loading view，解决 `NSPanel.orderOut` 不保证 SwiftUI `onDisappear` 的取消漏洞。
- App build 暴露并已修复严格并发错误：主线程 `NSView` selection host protocol/implementation 统一 `@MainActor`；同时完成 controller/details/action/OCR helper 拆分，SwiftLint changed-file gate 恢复为 0 violations。
- 自动化证据：Package tests 262 passed/3 skipped；完整 `MacClippyTests` 181 passed/1 skipped；新增 Preview selection tests 6 passed；App build-for-testing succeeded；`git diff --check` passed。
- 仍未证明：真实截图上的鼠标拖选视觉对齐、用户剪贴板中的图片数据、VoiceOver、Reduce Motion 真实 UI、TCC 和 Instruments。Computer Use 在本机因同 bundle ID 的多个 App 目标导致状态读取超时，未将其当作通过证据。

## Preview OCR selection bug follow-up（2026-08-10）

- 截图中的橙色实心矩形来自 selection view 直接用 `controlAccentColor` 填充 character/line bounding box；当 Vision character geometry 不完整时，整行 fallback 会把截图内容大面积遮住。
- 已改用系统 selected-text background、字符 highlight inset/圆角和低透明度 fallback line outline；这保留选区可见性，同时避免高亮遮挡文字。
- `⌘C` 原先依赖 general router 先判定为 `.native`，并且严格比较完整 modifier flags；Preview 是 non-key panel 时这条链路不稳定。现在 OCR selection 在 general action resolution 前直接路由，modifier 判断使用 device-independent mask。
- 全仓 Swift source 搜索没有发现有效的 `AI` button；现有 `MacClippyDockPreview.swift` header 没有该入口。截图中的 AI 文本应由旧 binary/旧 App instance 提供，需退出旧实例后运行最新 build。

## Preview OCR selection bug follow-up 2（2026-08-10）

- 首次 build blocker 的根因是 `MacClippyDockPreviewImageSelectionDrawing.swift` 未列入 `project.yml`，且 drawing extension 无法访问原文件的 `private/fileprivate` nested types；已修复并由 Debug build 覆盖。
- Preview 是 `.nonactivatingPanel`，普通 `NSHostingView` 和 selection view 未声明 first-mouse 接收，首个拖选可能只恢复窗口激活而不进入 `mouseDown`; 已增加专用 Preview hosting subclass 和 selection view override。
- 直接 Vision probe 读取用户提供的 PNG：749×236 截图返回 12 行，1054×672 截图返回 53 行；因此“新截图完全不能 OCR”不是 PNG 解码或 Vision service 的普遍失败。若用户仍看到旧 `AI`，优先排查旧 App 进程/同 Bundle ID 产物。
- 视觉层改为动态系统 accent、较明显但仍半透明的 highlight，并用 `Text selected · ⌘C to copy` 提示明确状态；提示设置 `allowsHitTesting(false)`，不遮断图片拖选。

## Repository cleanup review（2026-08-10）

- 已删除仓库内可重建生成物：根 `.build/`、根 `build/`、`MacClippyKit/.build/`、`MacClippyKit/build/` 和 `MacClippyKit/.swiftpm/`；总计释放约 26GB。
- 已删除 4 个 `.DS_Store`；没有残留 `.xcresult`、`.xcuserstate`、`DerivedData` 或其他 `.build` 目录。
- `dist/MacClippy.dmg` 作为当前 signed 构建产物保留；依赖锁文件也保留，因为 CI 和 clean build 需要它们。
- 静态引用检查没有发现未被 `project.yml` 引用的 App Swift 文件，或未被 Makefile/CI 引用的脚本；SwiftLint 182 个文件为 0 violations。
- 历史计划、审查报告和 DOCX 是 Git 跟踪的项目文档，不能仅因不参与编译就判定为无用，因此未删除。

## TCC permission / signing review（2026-08-10）

- `/Applications/MacClippy.app` 当前 bundle identifier 为 `com.macallyouneed.macclippy`，签名为 `adhoc,linker-signed`，没有 `TeamIdentifier`。
- `/Applications/VoiceFlow.app` 当前 bundle identifier 为 `com.voiceflow.desktop`，签名为 `Apple Development: frank19970907@gmail.com (777BPJR98D)`，`TeamIdentifier=2N55H39FC4`。
- MacClippy 的 Settings 页面已经显示 `Bundle.main.bundleURL.path`，并且调用 `AXIsProcessTrusted()` 与 `CGPreflightListenEventAccess()`；代码层权限 API 不是当前最高概率根因。
- MacClippy 当前 `make dmg` 默认设置 `CODE_SIGNING_ALLOWED=NO`，所以生成的 DMG 会安装一个 adhoc App。VoiceFlow 的构建 target 会自动从 Keychain 选择 Apple Development / Developer ID identity，并把 identity 传给 Tauri bundler。
- macOS TCC 权限与应用的 bundle/path/signing identity 绑定；每次重新产生或替换 adhoc App 都可能使已授予的权限不匹配当前进程。稳定 Team ID 的 signed build 是本机 TCC 验证的必要条件之一。
- 计划：让 MacClippy 的本机 `dmg`/archive 流程优先自动探测现有签名 identity；缺少 identity 时保留 unsigned fallback，并在输出中明确说明它不适合验证 TCC 或公开分发。
- Keychain identity 的 CN 括号值不一定等于 Team ID：当前证书 CN 末尾为 `777BPJR98D`，但证书 Subject 的 `OU` 和 VoiceFlow 签名实际 Team ID 都是 `2N55H39FC4`。Team ID 必须从证书 Subject OU 解析，不能从 identity 文本括号解析。
- Makefile 已改为从 Keychain 自动选择 identity，并通过证书 Subject OU 解析 Team ID；当前机器的 signed MacClippy 构建已成功，`codesign --verify --deep --strict` 通过，App 的 `TeamIdentifier=2N55H39FC4`。
- 该签名是 Apple Development，适合本机 TCC/功能验证，不等于 Developer ID、notarized 或 Gatekeeper 可发布产物；公开发布仍需 Developer ID + notarization。

## Dock 单选删除快捷键（2026-08-10）

- 用户症状是 Dock 中选中一张卡片后按 `⌘Delete` 没有反应。
- 输入路由的判断条件只允许 `hasMultipleSelection`，因此单选卡片没有产生 `.deleteSelection` action。
- 现改为 focused card 或多选均可产生删除 action；删除执行路径已经存在单选 fallback，不需要新增删除模型逻辑。
- Forward Delete（keyCode 117）也一并覆盖，避免不同键盘布局下行为不一致。
- 删除只在有焦点卡片或有效多选时触发，避免 Dock 没有选中内容时误删。

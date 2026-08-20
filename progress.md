# MacClippy Review Progress

## Session 1

- 已读取 `audit`、`impeccable` 和 `planning-with-files` 规范。
- 已确认设计上下文来自用户提供的重构计划：个人效率用户、开发者、键盘优先、原生克制快速。
- 已创建 review 计划和发现记录文件。
- 已完成 worktree、项目结构、构建配置、CI、测试库存和高风险模式的第一轮索引。
- 已确认当前项目没有 Sparkle/appcast/updater 实现；更新功能属于未覆盖范围。
- 已发现 planning 文件原有用户内容被本轮启动操作覆盖，后续必须优先处理记录恢复问题，不能继续无视。

## Session 2

- 已核实生命周期、Pasteboard、Pinboard、FTS 分页、UI 错误/加载状态和动画实现；新增证据已追加到 `findings.md`。
- 一次包含发布关键词的并行只读命令被环境 Guard 拦截，未执行任何发布动作；改用逐文件读取方式继续审查。

## Session 3 — Implementation continuation

- 恢复了 `MacClippyRuntime.swift` 中被 Runtime model 拆分误删的 `macClippyRuntimePerformanceLog`，避免性能 signpost 引用造成 App 编译失败。
- 执行 `xcodegen generate`，确认新拆分的 Runtime、Dock、Settings 和 Store 文件进入生成工程。
- 执行 Debug arm64 macOS App build，结果为 `BUILD SUCCEEDED`。
- build 输出仍提示当前 CoreSimulator framework (`1051.54.0`) 低于 Xcode 所需版本 (`1051.55.0`)；该警告不影响本次 macOS App build，但阻塞可靠的 Simulator/App XCTest 结论。
- 将 `task_plan.md` 从 review-only 计划同步为 implementation 状态，并记录当前已完成阶段、验证顺序和 release-only 环境限制。

## Session 4 — Validation completion

- `./scripts/lint.sh`：165 个 Swift 文件，0 violations。
- `swift test --package-path MacClippyKit`：259 passed、3 skipped、0 failures。
- `make test-scale`：100,000 条记录分页/搜索与 20MB representation 通过。
- `make test-stress`：10,000 次 observer lifecycle 通过。
- `swift test --package-path MacClippyKit -Xswiftc -strict-concurrency=complete`：259 passed、3 skipped、0 failures。
- `swift test --package-path MacClippyKit --sanitize=thread`：259 passed、3 skipped、0 failures。
- App XCTest 构建完成并启动 app，但 LaunchServices worker 未 materialize；中断后为 `TEST INTERRUPTED`，没有 assertion failure 结论。
- Release unsigned build 命令被环境 Guard 拦截，未执行发布授权绕过。
- `git diff --check` 通过；worktree 中既有的大量 dirty changes 和新增拆分文件均保留。
- 最终同步 `task_plan.md`：Runtime、Dock、Controller、Settings 和 ClipboardStore 的 extension 拆分标记为完成。

## Session 5 — Preview OCR selection plan update

- 根据用户要求 dispatch subagent，对图片 Preview OCR 选择方案进行独立只读 review。
- Review 确认原方案方向可行，但指出多个透明 `NSTextView`、Preview 非 key window、仅 line bounding box、Preview OCR 复用 Runtime lifecycle 和重复图片解码存在 P1 风险。
- 新建 `PLAN-preview-image-text-selection.md`，改为单一 AppKit selection coordinator、字符/文本片段 geometry、Preview 专属 generation/cancellation、shared bounded `CGImage` 和 fallback OCR text。
- 在 `task_plan.md` 增加 Phase 8 计划摘要，在 `findings.md` 记录 review 证据。
- 本次仅更新计划和研究记录，没有修改 Swift、数据库、工程或发布脚本。

## Session 6 — Preview OCR selection implementation

- 修复 Preview image state 从 `NSImage` 到 `CGImage` 的残留赋值错误；task id 改为 RecordID + Data fingerprint，root content identity 防止导航时旧 OCR 状态串入新内容。
- 新增 AppKit OCR selection view：共享 bounded image、Vision coordinate mapping、line/character hit-testing、跨行/反向 selection、整行 fallback、统一 `⌘C` 路由和 Copy Text。
- 加入 Preview-only OCR layout actor cache（8 entries / 2MB estimated cost），不保存原始图片、不写 Runtime 数据库；关闭 Preview 时 root reset，确保旧 OCR task 取消。
- 补充 geometry、selection policy、Unicode、stale offset、OCR layout DTO tests；修复一处 portrait aspect-fit 测试期望错误。
- 为 SwiftLint 拆分 selection endpoint、key actions、Details controller 和 OCR observation helpers；`./scripts/lint.sh` 最终 0 violations。
- 验证结果：`swift test --package-path MacClippyKit` 262 passed/3 skipped；完整 `MacClippyTests` 181 passed/1 skipped；Preview selection tests 6 passed；App `build-for-testing` succeeded；`git diff --check` passed。
- Computer Use 本次读取本地 App 超时，原因是同 bundle ID 的多个 App 实例和窗口状态不明确；未通过 UI 工具伪造拖选或 VoiceOver 验证结论。

## Session 7 — Preview selection polish and keyboard fix

- 修复 OCR selection UI：从 app accent 实心矩形改为系统 selected-text appearance；字符几何完整时绘制轻量圆角字符选区，fallback 时使用低透明度整行 tint + outline。
- 修复图片 Preview `⌘C`：在 general key action 前直接调用选区 host；统一 command-copy modifier 判定，并为 AppKit responder 增加 key-equivalent fallback。
- 代码搜索确认当前 Preview 源码没有 AI button；重新 build 的 header 不包含该入口，旧截图对应旧构建/旧 App 实例。
- `./scripts/lint.sh`：0 violations。
- `swift test --package-path MacClippyKit`：263 passed、3 skipped、0 failures。
- Preview App tests：7 passed、0 failures；`build-for-testing`、Debug build、`git diff --check`：通过。
- App test 日志仍有本机 `linkd.autoShortcut` 和已有 layout recursion warning，但不影响本次 7 个 Preview selection assertions；未将其误报为零 warning。

## Session 8 — Preview first-click and selection visibility fix

- 修复新 selection drawing 文件未进入 Xcode target、nested type 可见性错误；执行 `xcodegen generate` 后工程可编译。
- 为 Preview hosting view 和 OCR selection view 增加 `acceptsFirstMouse`，修复刚打开 Preview 直接拖选时首击被 nonactivating panel 消耗的问题。
- 选区改用动态 macOS accent color，提高描边/填充对比度，并增加不暴露剪贴板正文的选中状态提示。
- 对用户提供的两张 PNG 直接运行 Vision OCR probe，结果为 12 行和 53 行；OCR 输入本身正常。
- 验证：Package tests 263 passed/3 skipped；Preview selection tests 8 passed；SwiftLint 0 violations；Debug App build 成功。
- 真实鼠标拖选、`⌘C` 和 TCC 仍需用户在退出旧实例后用最新构建手动确认。

## Session 9 — TCC permission / signing diagnosis

- 对比当前 App 与 `/Users/mingjie.wang/Documents/personal/voice-flow`：VoiceFlow 的 `/Applications/VoiceFlow.app` 使用 `Apple Development` identity 和 Team ID `2N55H39FC4`；MacClippy 的 `/Applications/MacClippy.app` 是 adhoc 签名且无 Team ID。
- 通过现有源码确认 MacClippy 已正确使用 `AXIsProcessTrusted()`、`CGPreflightListenEventAccess()` 和 exact bundle path 展示；当前症状更符合 unsigned/adhoc 替换导致 TCC 身份不匹配，而不是权限 URL 或状态 API 缺失。
- 确认 VoiceFlow Makefile 会自动选择 Keychain 中的 Apple Development / Developer ID identity；MacClippy 的本机 DMG target 目前默认关闭代码签名。
- 下一步：复用同样的 identity discovery 方式接入 MacClippy 本机打包流程，并用 signed App 验证 metadata、签名和 DMG 内容；不把 Apple Development 签名误报成 Developer ID/notarized release。
- 第一次自动签名构建被 Xcode 拒绝，因为从 identity CN 括号错误解析出了 `777BPJR98D`；通过 `security find-certificate` + `openssl x509` 确认真实证书 OU/Team ID 为 `2N55H39FC4`，已将 Makefile 解析逻辑修正为读取证书 Subject OU。
- 修正后 `make dmg` 使用 `Apple Development: frank19970907@gmail.com (777BPJR98D)` + `DEVELOPMENT_TEAM=2N55H39FC4` 构建成功；DMG checksum 有效，signed App 严格验证通过。
- 真实 TCC 尚未在新 App 上执行；用户需要用新 DMG 替换旧 adhoc `/Applications/MacClippy.app`，从该固定路径启动，并在 Accessibility/Input Monitoring 中移除旧条目后重新添加。

## Session 10 — Repository cleanup

- 盘点发现 `.build/` 约 12GB、`build/` 约 14GB、`MacClippyKit/.build/` 约 839MB、`MacClippyKit/build/` 约 9MB；这些均为可重建生成物。
- 扩展 `make clean` 覆盖根 `.build`、根 `build`、SwiftPM `.swiftpm`、`MacClippyKit/.build` 和 `MacClippyKit/build`，保留 `dist/MacClippy.dmg`、依赖锁文件、源码、测试和计划文档。
- 删除仓库内 4 个 `.DS_Store`。
- 第一次幂等复跑发现不存在目录时安全检查误报越界；已修正为允许 canonical probe 落在仓库根目录，同时继续拒绝仓库外 symlink。
- 清理后仓库约 15MB，`dist/MacClippy.dmg` 约 8.7MB；`make clean` 可重复执行并成功。
- `./scripts/lint.sh`：182 个 Swift 文件，0 violations / 0 serious violations。
- `git diff --check`：通过；静态引用检查未发现未引用 App Swift 或打包脚本；仓库内无残留临时缓存模式。

## Session 12 — PLAN 落地审计 + Search 复审（2026-08-19）

- 对照 `PLAN-full-app-review-improvement.md` 逐阶段核对代码：P1 pasteboard snapshot 与 History/Pinboard 分页主路径已落地，但计划整体未完成。
- Search 独立复审：发现 CJK/子串、三套搜索后端、FTS rank vs recency、snippet 尖括号、Pinboard empty copy、Esc 不清空 query 等产品缺口。
- 结果写入 `findings.md` 与 canvas `plan-and-search-review.canvas.tsx`。本次只做审查，没有改 Swift。
- [Audit P1–P3](b67830e5-f644-4552-aefc-efdfdf1b9100) 与 [Audit P4–P9](bca7aeb7-a9a7-4098-8191-616e54ed33f5) 交叉核对后补记：无 query 的 Pinboard item 分页仍静默失败；Copy false toast / 多 representation restore / page retry / file-icon waiter 缺测试；Dock open/keystroke/scroll 无 UI signpost；notarize 不在 CI。

## Session 11 — Dock 单选卡片 `⌘Delete` 修复（2026-08-10）

- 根因：`MacClippyDockInputPolicy.selectionAction(...)` 之前只在存在多选时返回 `.deleteSelection`，单选 focused card 的 `⌘Delete` 被当作普通/native 事件处理。
- 修复：删除判断现在接受 `hasCardFocus || hasMultipleSelection`，同时覆盖 macOS Delete（keyCode 51）和 Forward Delete（keyCode 117）。无焦点时仍不会误触发删除。
- Controller 已确认把 `model.focusedPreviewTarget != nil` 传入 router；model 的 `deleteSelected()` 在单选场景复用既有 `deleteFocused()` fallback，在多选场景保持批量删除。
- 新增回归覆盖：单选 `⌘Delete`、单选 `⌘Fn+Delete`、多选删除和无焦点安全行为。
- 为避免这次快捷键修复扩大 router 复杂度，按 key-up、preflight、content、selection、navigation 和 search input 拆分私有路由 helper，并用 context value 传递 key-down 状态。
- 最终验证：`swift test --package-path MacClippyKit` 通过（264 passed、3 skipped、0 failures）；`./scripts/lint.sh` 通过（182 files、0 violations）；macOS Debug App build 成功；`git diff --check` 通过。
- 构建仍报告本机 CoreSimulator framework 版本低于 Xcode 的环境 warning，但 macOS App target 正常完成 build；未将该 warning 当作 App build 失败。

## Session 13 — 实现计划中代码可落地项（2026-08-19）

- Search：CJK LIKE 子串、短语/`prefix*` FTS match、History recency 展示、去掉 snippet `<>`、`type:url`、文件名-only 索引、Pinboard OCR/label/FTS、Esc 先清 query、No matches empty copy、冲突 type 文案。
- Dock/a11y：Dynamic Type 高度、carousel edge fade、contrast 环境、`dock_open`/`search_keystroke`/`card_scroll` signpost。
- 错误：`MacClippyUserFacingError.message(for:)` 区分 missing/corrupt/permission/storage；History/page/details 已接入。
- Pasteboard：image 与 URL+text 多 representation 失败 restore 测试。
- 未做且不能报完成：Developer ID / notarization / Gatekeeper、真实 TCC、Instruments、soak、retention 单 owner、OCR+FTS 同事务、Copy Bool→throwing API、SwiftUI Equatable card（isolation）。

## Session 14 — 修复独立 review 的 Critical / Important / Minor（2026-08-19）

- Critical：Pinboard `visibleItems` 不再在 debounce 或首次 in-flight 时返回 `[]`；无结果只在 settled 空搜索后出现。
- Important：`type:url` SQL 与 `matchesURL` 对齐；Pinboard FTS 去掉 10k 上限并移出 store lock；History 累计页和 Cmd+A 按 recency；VO 挂钩 `pinboardSearchIsLoading` / `filteredSnippets`；空 carousel Retry 走 `retryCurrentPage`；highlight range 合并；`card_scroll` observer 在 dismantle/deinit 拆除。
- Minor：FTS snippet 改 RS/US marker；混合 CJK+ASCII 拆成 FTS+LIKE；`type:url type:image` 视为冲突；GRDB/SQLite 走 `MacClippyFailureClassification`；删除无调用方的 `pinboardItems(... query:)`。
- 未做且不能报完成：同上 Session 13 的发布/TCC/Instruments 项；`SearchStore.search(query:)` 兼容拆词未改；卡片仍未接 `.equatable()`。
- 验证：`./scripts/lint.sh` 205 files、0 violations；`swift test --package-path MacClippyKit` 286 passed / 3 skipped；Debug App `BUILD SUCCEEDED`；metadata verifier 通过；focused App tests 19 passed；`git diff --check` 通过。未 commit。

## Session 15 — 全库精简清理（2026-08-19）

- 删除未接线的 `MacClippyDockCardUpdate` 脚手架及其测试。
- 删除零调用 Runtime/UI 辅助：`structuredHitProjection`、未使用的 `markSearchRepairNeeded` 包装、`iconName(for:)`、旧 `MacClippyDockCardClickPolicy`、静态 `carouselHeight`。
- 删除 Kit 死 API：`recentByFrequency`、`prefersSubstringSearch`、`SnippetExpansionSettings.save`、未使用的短 typealias。
- 删除已落地的 Settings/Dock PLAN、`MacClippy-Prod-Readiness-Goal.md`、Word 报告和生成脚本。保留 `PLAN-full-app-review-improvement.md`、`PLAN-preview-image-text-selection.md` 以及 task_plan/findings/progress。
- 未删：`SearchStore.search(query:)`（lint 边界 + 测试仍用）、`filter(_:by:)`（History 仍用）、`pendingDeletions`（journal 测试 API）、发布脚本和 CI。
- 验证：lint 203 files、0 violations；package 286 passed / 3 skipped；Debug App `BUILD SUCCEEDED`；focused App tests 通过；metadata verifier 与 `git diff --check` 通过。未 commit。

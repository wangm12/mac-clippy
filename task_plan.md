# MacClippy 全量重构与 Improvement 实施计划

## 目标

在保留现有 dirty changes 和数据库/加密格式的前提下，完成计划中已经进入当前 worktree 的性能、生命周期、分页、架构拆分、展示策略、动画和验证改进。实现顺序遵循“先正确性，再性能，再结构和体验”，不把未具备环境证据的发布能力误报为已完成。

## 成功标准

- P1 生命周期、展示策略、Snippet event tap、批量读取和全量搜索 materialization 风险有代码与回归测试覆盖。
- Runtime、Dock、Controller、Settings 和 ClipboardStore 已按职责拆分，App-facing façade 保持可用。
- Debug App build、Package tests、lint、metadata verifier 和 diff 检查可复现。
- UI 后台结果只回到 MainActor，分页/搜索/缩略图/OCR 有界且可取消。
- 真实 TCC、VoiceOver、高对比度、Instruments、soak、Developer ID、Notarization 和 Gatekeeper 作为 release-only gates 明确记录，不以本地 Debug 结果替代。

## 阶段

- [completed] 1. 恢复实现上下文并修复 App build blocker
- [completed] 2. 生命周期、展示策略、Snippet 和 OCR correctness
- [completed] 3. ClipboardStore batching、keyset pagination 和 structured search
- [completed] 4. Runtime/Dock/Settings/Store 职责拆分与 MainActor 边界
- [completed] 5. 静态检查、package/App 验证和发布脚本验证
- [completed] 6. 最终 diff 审查、已完成项与环境限制交付
- [completed] 7. Add Category 点击可靠性、创建状态与 Apple-inspired 颜色收口
- [in_progress] 8. 图片 Preview OCR 文字选择、复制与 AppKit selection engine（代码完成；真实 UI smoke pending，详见 `PLAN-preview-image-text-selection.md`）
- [in_progress] 9. TCC 权限与稳定 code-sign identity（构建流程和 signed DMG 已完成；真实 TCC smoke 需用户替换 App 后确认）
- [completed] 10. 仓库缓存与生成物清理（保留 signed DMG、源码、测试、依赖锁文件和审查文档）
- [completed] 11. Dock 单选卡片 `⌘Delete` 快捷键修复与回归验证
- [completed] 12. 对照 `PLAN-full-app-review-improvement.md` 做落地审计，并独立复审 Search（详见 findings.md 与 canvas）
- [completed] 13. 实现计划中代码可落地的 Search / Dock / a11y / 错误文案缺口（不含 Developer ID、公证、真实 TCC、Instruments、soak）
- [completed] 14. 修复独立 review 的 Pinboard 闪空、`type:url` 不一致、Pinboard FTS 锁/上限、History 累计 recency、VO/Retry/highlight/signpost 与若干 minor
- [completed] 15. 全库清理：删除零调用代码、未接线脚手架、已落地 PLAN 和生成报告，不改 SearchStore/ClipboardStore 本体

## Phase 8 计划摘要

- Apple `ImageAnalysisInteraction` 不支持原生 macOS 14，采用 Vision + AppKit 自建图片文字选择层。
- 不使用每行一个透明 `NSTextView` 的方案；改为单一 selection coordinator，统一处理跨行、反向拖选和 `Cmd+C`。
- Preview OCR 独立于 Runtime 持久化 OCR，绑定 Preview generation、RecordID 和 content fingerprint，不写数据库。
- display 和 OCR 共用一个 bounded `CGImage`，避免重复解码；OCR cache 只保存 layout DTO。
- 需要新增字符/文本片段 geometry、非 key Preview keyboard routing、fallback OCR text 和对应 App/UI/performance tests。

## 当前验证顺序

1. `xcodegen generate` → 确认生成工程包含所有新增 Swift 文件。
2. `./scripts/lint.sh` → 修复由本次实现引入的 lint violation。
3. `swift test --package-path MacClippyKit` → 验证 Core/Platform regression tests。
4. `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` → 验证 App Debug 编译。
5. `./scripts/verify-build-metadata.sh <app>` → 验证 bundle metadata，不要求静态 `LSUIElement=true`。
6. `git diff --check`、`git status --short`、`git diff --stat` → 完成交付前审查。

## 阶段七验证

- Add Category 和 Settings icon 使用 40pt 外层命中区域，图标视觉尺寸保持紧凑。
- Dock panel 的 `NSHostingView` 和 content container 接受 first mouse，避免 nonactivating panel 的第一次点击只用于激活窗口。
- Category color selector 使用 40pt 命中区域、selected checkmark、accessibility value/identifier。
- 新 category 只有在后台创建成功后才关闭 modal；失败时保留表单并允许重试。
- Palette 更新为 8 个稳定的 macOS Theme-inspired HEX（blue/purple/pink/red/orange/yellow/green/graphite），并补充语义名称和 Core regression test；旧的自定义 HEX 仍原样保留。
- Category modal 宽度调整为 460pt，内边距调整为 28pt，section 间距调整为 20pt，颜色行不再贴边。
- `./scripts/lint.sh`：0 violations。
- `swift test --package-path MacClippyKit`：260 passed，3 skipped，0 failures。
- Debug App build：`BUILD SUCCEEDED`。
- Metadata verifier：通过。
- `git diff --check`：通过。

## 验证结果

- lint（2026-08-19 Session 15）：203 个 Swift 文件，0 violations / 0 serious violations；changed-file gate 通过。
- Package tests：286 passed，3 skipped，0 failures。
- Focused App XCTest：SearchProduct / EmptyState / UserFacingError / PinboardVisibleItems / DockTests / MotionTests 通过。
- Debug App build：`BUILD SUCCEEDED`；metadata verifier 通过。
- `git diff --check`：通过。未 commit。

## 历史验证结果

- lint：165 个 Swift 文件，0 violations / 0 serious violations。
- Package tests：259 passed，3 skipped，0 failures。
- Strict concurrency package tests：259 passed，3 skipped，0 failures。
- Thread Sanitizer package tests：259 passed，3 skipped，0 failures。
- Opt-in scale tests：100,000-record pagination/search 与 20MB representation 均通过。
- Lifecycle stress：10,000 次 observer start/poll/stop 通过。
- Debug arm64 App build：`BUILD SUCCEEDED`。
- Debug metadata verifier：通过。
- `git diff --check`：通过。
- App XCTest：构建完成但运行阶段卡在 LaunchServices worker，手动中断并得到 `TEST INTERRUPTED`；没有 assertion failure 结果。
- Release unsigned build：被当前环境 Guard 拦截，未执行绕过操作。

## 已完成实现摘要

- OCR lifecycle generation/token、queued cancellation、active/pending budget 和写库前 fence。
- disabled Snippet 不安装 event tap，并支持 preference 动态 start/stop。
- SQLite ID 查询按 500 分批，保留输入顺序、重复 ID 和缺失 ID 语义。
- FTS/history 与 Pinboard 使用稳定 cursor/keyset 分页，避免全量 materialization。
- All/Snippet 不展示数量，加载更多由分页 continuation 驱动；Command+A 作用于完整结果集合。
- Runtime、Dock、Controller、Settings 和 ClipboardStore 已按职责拆分为 façade + extension，`MacClippyDockModel` 显式 MainActor 隔离。
- 动态菜单栏/Dock policy、fallback Settings window 清理、Reduce Motion 和性能 signpost 已保留。

## 未能在当前环境证明的项目

- 真实 TCC（Accessibility/Input Monitoring）、VoiceOver、高对比度和多显示器交互。
- Instruments Core Animation/Allocations/Energy、长时间 soak、真实 10k/100k release 性能预算。
- Developer ID 签名、Hardened Runtime release artifact、Notarization、staple 和 Gatekeeper。
- App XCTest 运行结果仍受当前 LaunchServices/CoreSimulator 环境限制；不能用作通过证明。
- 图片 Preview 的真实拖选、`⌘C` 复制和 VoiceOver 交互尚未在用户数据/TCC 环境中完成手动 smoke；Computer Use 在当前机器上因多个同 bundle ID 的 App 实例和窗口状态超时，不能作为通过证据。

## 阶段八实现与验证

- Vision OCR 新增 line/character geometry DTO；保留原有 String OCR API。
- Preview 图片和 OCR 共用一份 1,600px bounded `CGImage`，OCR 不写数据库。
- AppKit 单一 selection view 支持 aspect-fit 坐标映射、单行/跨行/反向拖选、Unicode grapheme 和缺失字符 geometry 的整行 fallback。
- Preview 非 key panel 的 `⌘C` 由 Dock Controller 显式路由；无 OCR 选区时保留原始图片 Copy；新增 Copy Text。
- Preview task 使用 RecordID + content fingerprint；关闭 Preview 时替换为 loading root，取消旧解码/OCR；layout cache 限制为最多 8 项/2MB 估算成本。
- selection geometry/policy、OCR layout 和 stale offset 回归测试已加入；Package tests 262 passed/3 skipped，App unit tests 181 passed/1 skipped，Preview selection tests 6 passed。
- `./scripts/lint.sh`：0 violations；App `build-for-testing`：成功；`git diff --check`：通过。

## Preview OCR selection follow-up（2026-08-10）

- 移除 Preview 选中层对 `controlAccentColor` 的依赖，改用 macOS `selectedTextBackgroundColor`；字符级高亮使用 inset/圆角，缺失字符几何时使用低透明度整行 fallback 和细边框。
- Preview 图片 OCR 的 `⌘C` 在通用 key router 前直接由 Dock Controller 路由到 selection host；AppKit modifier flags 先取 device-independent mask，保留 `performKeyEquivalent` 兜底。
- 当前源码和重新构建的 Preview header 没有 `AI` 功能入口；截图中的 `AI` 来自旧运行产物/旧 App 实例，当前 header 仅保留 Copy、Copy Text、导航和关闭。
- 新增选中外观与 command-copy regression tests；完整 Package tests 263 passed/3 skipped，Preview App tests 7 passed，SwiftLint 0 violations，Debug build/build-for-testing 和 `git diff --check` 通过。

## Preview OCR selection follow-up 2（2026-08-10）

- 修复 selection drawing 拆文件后的工程阻塞：`MacClippyDockPreviewImageSelectionDrawing.swift` 已加入 `project.yml`，selection nested types 调整为同 target 可见，`xcodegen generate` 后 App build 成功。
- Preview hosting view、OCR selection view 均接受 first mouse，避免 nonactivating preview 的首个拖选动作只用于激活窗口。
- 选区使用动态 macOS `controlAccentColor`，提高字符/整行边框和低透明度填充对比度；选中后显示不泄露正文的 “Text selected · ⌘C to copy” 状态提示。
- 直接对用户提供的两张 PNG 运行 Vision probe：分别识别 12 行和 53 行；证明图片格式和 OCR service 输入链路正常。
- 当前验证：SwiftLint 0 violations；Package tests 263 passed/3 skipped；Preview selection tests 8 passed；Debug App build 成功。
- 仍需用户在退出旧实例后启动最新 `.build` App，使用真实 TCC/鼠标拖选验证；本地存在多个同 Bundle ID App 产物，Computer Use 无法可靠选定目标实例，不能把它当作手动 UI 通过证据。

## 错误记录

| 错误 | 尝试 | 处理 |
|---|---:|---|
| `macClippyRuntimePerformanceLog` 缺失导致 App 编译失败 | 1 | 在 `MacClippyRuntime.swift` 恢复 scoped `OSLog` 常量；Debug build 已通过 |
| 新增 Swift 文件未进入旧工程文件列表 | 1 | 通过 `project.yml` 更新后执行 `xcodegen generate`；后续 build 已包含拆分文件 |
| CoreSimulator framework 版本落后于 Xcode | 环境限制 | macOS App build 仍成功；App XCTest/Simulator 相关结果不作通过证明 |
| App XCTest LaunchServices worker 未 materialize | 1 | 构建已完成但运行卡住；安全中断，保留 `.build/AppTests.xcresult` 作为环境诊断，不宣称 App tests 通过 |
| Release unsigned xcodebuild 被环境 Guard 拦截 | 1 | 不绕过发布授权；Debug/package/metadata 结果仍有效，Release/签名/公证留作本机 release gate |
| Preview portrait aspect-fit 测试期望错误 | 1 | 按 800×1600 放入 400×300 的真实 aspect-fit 结果修正为 150×300，测试通过 |
| Computer Use 读取本地 Preview 超时 | 1 | 已确认存在多个同 bundle ID App 实例；不强行操作其他实例，记录为真实 UI smoke 的环境限制 |

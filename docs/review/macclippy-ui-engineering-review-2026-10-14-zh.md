# MacClippy 独立工程复审

审查日期：2026-10-14。只读检查源码、修复 diff、测试与原生验收数据；未修改仓库，未操作 GUI，未启动测试、构建或窗口。此报告文件是本轮唯一写入。

## 结论

已完成 UI/workflow 端到端静态复查、Pinboard 精确修复 delta 的独立复审及最终验证证据核对。此前发现的唯一 P2——提交中的 Esc 取消对话框、旧创建回调关闭新对话框——已闭环，新增四条回归均通过。**当前未发现剩余确认 P1/P2**。最终 App 500 条、Python 39 条通过，SwiftLint 535 文件零违规；Release E2E 的 source SHA 与 manifest 相符，611 个已记录 build inputs 逐文件核对无差异。

最新 Cua 焦点交接、nonactivating Details、native Help、opt-in recipient 与 readiness 修改未发现新的 P1/P2。先前已确认的 selection、搜索、固定目标、迟到 overlay 与消费事件问题在本轮源码中均已修复。

VoiceOver 根据用户最新明确要求排除，不作为验收缺陷或未完成项。

## 审查版本与范围

- 主审修复专用 diff：[macclippy-cua-final-review.patch](/tmp/macclippy-cua-final-review.patch)，文件列表：[63 files](/tmp/macclippy-cua-final-review-files.json)。没有把整个脏工作树归因于本轮修复。
- 后续精确 delta：[macclippy-pinboard-review-fix.patch](/tmp/macclippy-pinboard-review-fix.patch)，4 个产品文件及 1 个新增测试文件（四条回归），已读完并核对当前源码与所有 createPinboard 调用点。
- 最终组合 diff：[macclippy-cua-pinboard-final-review.patch](/tmp/macclippy-cua-pinboard-final-review.patch)，64 paths，包含该精确修复与新增测试。
- 早期修复 baseline：`/var/folders/gm/g2vs8nvn4tn2108l6l6t87gc0000gp/T/macclippy-review-fix-baseline-ic35s64i`；原生修复 baseline：`/tmp/macclippy-cua-fix-baseline`。
- 最终工程验证 source SHA：`4440f13fd2e16204c8fb5932f48da58382f4231e69ea307f866ead44afabe883`。直接读 [manifest](/tmp/macclippy-cua-pinboard-final-manifest.json) 与最终 bundle Info.plist，两者一致；611 个 manifest build inputs 的 SHA/字节数与当前文件一致。
- 最终 Release bundle：`/tmp/macclippy-review-fix-e2e-derived6/Build/Products/Release/MacClippyE2E.app`，bundle identifier `com.macallyouneed.macclippy.e2e`、configuration `Release` 已核实。
- 已有完整原生验收数据仍绑定修前 SHA `272ed21dbcfa057c2c43e06b7b12bb595ccf31b7b1802586f56f184cf8ce98d4`。最终新 build 的原生 critical 复验正由独立 GUI reviewer 进行；此工程报告不冒充该 GUI 复验。
- 保留用户确认的底部横向卡片、双击复制关闭、搜索第一次 Return 进入结果、第二次 Return 粘贴。未扩展至迁移或底层大重构。

## 已修复确认问题

### 已闭环 P2：旧 Pinboard 创建完成能关闭新的对话框

此问题属于修前现有 UI 实现，不是 Cua 焦点/Help 修复引入。修前触发链是：Create 的本地 Cancel 被禁用，但 controller 的 `.modal` Esc 仍 dismiss；同 session 新开窗口后，旧创建完成只检查 session，仍 selectTab 并调用旧 View completion，无条件 dismiss 新 modal。静态调用链已确认，不声称已在 GUI 复现。

修后入口与完成身份已闭环：

- 创建需要 caller 捕获的 modalToken，验证当前 `.createCategory(token:)`，同一次提交期间拒绝重复请求：[Categories.swift:97](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Categories.swift:97)。pending identity 保存 session+modalToken。
- 迟到完成先验证其仍拥有 pending identity，再清自己的 pending；之后检查当前 session+modal 相同，才可 selectTab、reload、dismiss、调用 editor completion：[Categories.swift:109](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Categories.swift:109)。旧完成因此不能清掉新创建的 pending，也不能更新 replacement modal 的范围。
- 成功 dismiss 已移到受守卫的 model 分支，View completion 只复位自己的提交状态：[Categories.swift:118](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Categories.swift:118)、[Modals.swift:94](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+Modals.swift:94)。View Cancel 另检查当前 token 和 pending 状态。
- controller 在 `.dismissModal` 时检查当前创建提交状态；`applyKeyAction` 仍返回 consumed，因此 Esc 不继续落到原生 responder：[KeyActions.swift:45](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:45)。teardown 使用 model 的原始 dismiss，仍可关闭当前面板；session guard 使旧完成无权恢复已关闭会话。
- failure 仅复位自己的 pending、错误和 completion；没有把另一 modal 的错误/输入覆盖。新请求同 token 重试仅在上一 completion 完成后允许。

四条新增回归的时序设计与修复相符，均通过 semaphore 固定工作队列时序，读取真实 Runtime 存储，覆盖提交中 Esc/重复提交、同 session replacement modal、旧完成到达时新创建 pending、旧 session 完成。对应 [测试入口:31](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyPinboardCreationWorkflowTests.swift:31)、[replacement:72](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyPinboardCreationWorkflowTests.swift:72)、[pending ownership:92](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyPinboardCreationWorkflowTests.swift:92)、[session:123](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyPinboardCreationWorkflowTests.swift:123)。已直接读最终 App 日志，四条全部 passed。本审查未自行启动测试：第一条直接 route Esc，验证 controller 的消费结果；实际安装 local monitor 的 nil 消费链由已有 native monitor 回归覆盖。四条没有新增 real NSMenu tracking 或 mounted Editor 输入验收。

## 先前问题闭环

| 原确认问题 | 当前源码中的闭环 |
| --- | --- |
| Cmd+A 未完成就复制/粘贴第一页；失败后回退子集 | `selectionIsReady` 统一检查 pending work 与 failure；失败清掉可见部分 IDs。model、keyboard 和 selection bar 入口都检查。真实 offscreen 加密行损坏回归验证不写入子集。 |
| 空结果全选后换查询永久 pending | query didSet 在非 ready 时失效旧范围，token/session/query/tab/generation 同时守卫结果。 |
| 失败的全范围挡住明确卡片 Pin/Delete | 只有隐式 selection 要求 readiness；显式 IDs 和已确认 IDs 独立执行，保留确认目标。 |
| 单项 ⌘P 与文档不符 | 有焦点的单项可走 chooser；Preview/Details 使用当前显示 ID，chooser 冻结目标 IDs。 |
| 无效日期吸入附加条件 | 日期字段严格验证唯一真实 YYYY-MM-DD；先验证日期范围，再写 query。 |
| 类型/来源筛选、未闭合引号、Snippet 切换损坏查询 | 关键词与结构条件经共同 composition policy，未完成 lexical token 不吞掉条件；native field commit 与 full-query replacement 分开。 |
| 搜索/菜单/Popover → Cancel 首次 Return 粘贴 | 逻辑 search intent 不因临时 native blur 丢失；OR overlay observer 捕获一次原意图；关闭前和 deferred restore 各有 session/reset/generation guard；独立 modal observer 不重捕搜索意图。 |
| 迟到关闭 observer 覆盖新的 Search/Preview | 验证打开时 session/reset 先于 `onModal(false)`；controller 仅在当前 `.modal` 时退到 picker。 |
| key monitor 重新返回已消费事件 | keyDown/keyUp 直接返回 `routeKeyEvent` 的可空结果。安装 monitor 后 `NSApp.postEvent(Esc)` 的 spy 回归确认原生 responder 不再收到已处理 Escape。 |
| picker 导航复用旧 preview target | 仅实际 Preview/Details 从显示 target 导航；picker 从当前焦点移动。 |
| Details loading/error Return、编辑和粘贴错误目标 | loading 消费 Return，error Return retry；action 和 save/load 完成使用固定记录 ID、request ID、editor 实例身份及 session；save and paste 不取过滤后的新焦点。 |
| 旧 snippet edit callback 打开旧内容 | callback 按 ID 查最新 snippet；独立 editor generation 防旧保存回调关闭新的 editor；lookup snapshot 预读在存储 commit 前完成。 |
| 旧 toast fade 隐藏新 toast | task cancellation、toastGeneration、panel identity 同时守卫延迟 fade/orderOut；screen toast 不随 Dock endSession 消失。 |

本轮重点实现证据：[Workflow.swift:5](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Workflow.swift:5)、[SelectionAll.swift:70](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+SelectionAll.swift:70)、[Modals.swift:8](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+Modals.swift:8)、[HeaderSearch.swift:118](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+HeaderSearch.swift:118)、[Details.swift:209](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Details.swift:209)、[Feedback.swift:69](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Feedback.swift:69)。

## 本轮原生修复与整体集成

- Resign-key 现在等待 AppKit handoff 完成，检查 monitor generation、重新获得 key、Details/Preview key、独立 Snippet editor、native modal、menu tracking 与 filter Popover，再判断 Space/真实 outside-click。Details 的 nonactivating mask 保持可 key。静态链路与两条新 native key handoff 测试一致：[Input.swift:65](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Input.swift:65)、[Details panel:224](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDetails.swift:224)、[KeyWindow tests:9](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyNativeSearchWorkflowTests+KeyWindow.swift:9)。
- 导航保留 History/Snippets 和所选 Pinboard，无法显示的板仍在原生 overflow menu 中；header 预算扣除 pause/ignore 状态占用的宽度，chip 仅在有足够空间时挂载；selection actions 横向滚动。已读预算测试的范围是 1024/1280/1440，不能把算式测试当成所有显示器上的实际 layout 验收。
- Card Copy/More、context menu、Preview/Details 操作明确传记录或 snippet ID；双击仍 Copy 成功再关闭，未被改成 Paste。More/help/settings 独立窗口入口先释放 Dock 生命周期，避免 Dock 的 local key monitor 接管这些窗口。
- 合并、顺序、transform、single record、snippet 在操作开始捕获 PID；Runtime/Injector 持续传递相同 PID 与 gate。新操作/session teardown 关闭旧 gate，late progress 和 completion 检查 session/operation/token。生产有 PID 时通过 `postToPid`，并未因修复把 targeted posting 退化成 global posting。
- Capture 状态来自 observer 的 lifecycle queue 读快照及主线程通知，pause/resume/ignore/cancel 都经相同异步状态发布；UI 没有先行猜测成功。没有发现确定的状态线程问题。
- Native Help 使用单一可选择 `NSTextView` 文档、纵向滚动、动态 labelColor，取当前开窗 shortcut。Return、双击、Copy、Tab、Esc、搜索条件说明与 README/路由一致。[Help.swift:21](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyHelp.swift:21)。
- native recipient 仅 `MACCLIPPY_E2E` 编译且只在 `native-host-show` 时创建，背景/soak 不自动开窗。控制通道仍限定 run-local named pasteboard 与 synthetic recipient。source-bound Python integration 覆盖未显式打开时 absent、Dock hide 后存在、一次隔离 paste 及 hide 生命周期：[test_macclippy_phase5.py:1066](/Users/mingjie/Documents/github/personal-projects/mac-clippy/scripts/e2e/test_macclippy_phase5.py:1066)。
- readiness 检查 visible/key/loading/content window，flush rendering 后读 foreground layer 可见 opacity；不依赖复用 carousel 再次 onAppear。此接口证明可交互的合成窗口面，不证明外部应用接受了粘贴。[E2EControlUI.swift:152](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyE2EControlUI.swift:152)。

## 测试有效性与证据边界

已直接读取日志，未自行重跑：

- [最终 App 测试](/tmp/macclippy-cua-pinboard-final-app-tests.log)：500 executed，2 skipped，0 failures，`TEST EXECUTE SUCCEEDED`；新增 Pinboard 四条全部 passed。两条 skip 仍为 opt-in 10k Runtime search fixture 和真实 session event tap；不影响这些 UI 修复的确定性回归结论。
- [最终 Python](/tmp/macclippy-cua-pinboard-final-python-tests.log)：39 tests，`OK`，无 skips；包括 source-bound full query 与 native host lifecycle 两条运行时 integration。
- [最终 SwiftLint](/tmp/macclippy-pinboard-fix-lint.log)：535 files，0 violations。
- [原生验收记录](/tmp/macclippy-cua-native-acceptance.json) 给出真实 app menu、context menu Edit、两次 Return、英文+类型搜索、真实 SCIM 候选确认、dirty Cancel、保存失败、保存后原 ID 排除出查询仍粘贴、snippet 四字段持久化、Help 可读/滚动且 Cua 不崩溃。报告者原始 [editor proof](/tmp/macclippy-build12-native-review/editor-proof.json) 记录了不同初始焦点 ID、编辑 ID、过滤排除与 insertionCount=1；[IME final proof](/tmp/macclippy-build13-native-review/ime-continuous-final.json) 本身是最终 recipient 状态，单独不能证明完整 IME 过程，本审查将该流程的 GUI 结论限定为原生验收记录提供的实测结果。
- 加强的 overlay 回归实际安装 local monitor 并 `NSApp.postEvent` 两次 Return，检查第一次不变 clipboard/operation、第二次 named pasteboard payload 与一次 paste+teardown。它仍手动发布 NSMenu begin/end 通知与 field blur，不能单独代替真实 Menu tracking 的 GUI 测量。[Overlays tests:36](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyNativeSearchWorkflowTests+Overlays.swift:36)。
- 外部实际应用的 CGEvent 接收未由这套 E2E 证明。测试中的 recipient 以 synthetic 插入模拟收到 paste，native window 显示该结果；源码/PID 测试与生产窗口行为应分别表述。
- App 日志的三个挂载 overlay case 仍报告 SwiftUI `Publishing changes from within view updates` warning。未发现可归因的失败、崩溃或错误状态路径，不升级成 P1/P2；不能把零失败描述为零运行时 warning。
- 原生宽度/多板溢出、鼠标菜单追踪/Popover outside-click、跨窗口导航矩阵由独立 GUI reviewer 验证。本工程审查未操作 UI，未用静态推导冒充视觉复现。

## 后续闭环

Pinboard P2 的源码、四条回归与最终全量 App/Python/lint/build identity 均已闭环，无剩余确认 P1/P2。独立工程审查结束。最后新 build 的原生 critical 复验由 GUI reviewer 独立记录；原生点击/视觉过程或外部 app 的实际 paste delivery 不由这份工程通过结论替代。

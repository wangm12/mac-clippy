# MacClippy 全量 Review 后续 Improvement Plan

> Owner: mingjie-father  
> Scope: MacClippy 全 App 质量、性能、交互、无障碍、架构与发布流程  
> Strategy: 先修复数据安全和搜索正确性，再优化并发/性能，最后做结构拆分和 release gate。  
> Constraint: 保留现有 dirty changes；不迁移数据库 schema，不引入网络同步，不重写 UI 框架。

## 1. 目标与完成标准

### 目标

- Copy、Paste、Search、Pinboard、Snippet、OCR 在失败、取消和重启时都保持数据正确。
- 搜索、横向滑动、Preview 和 Dock 打开不因全量读取、过长锁或过多 SwiftUI 重绘产生明显卡顿。
- 错误具有明确类型、准确的用户反馈和对应 Retry，不把基础设施错误伪装成“没有数据”。
- 保持原生、克制、键盘优先的 macOS 交互，并完善 VoiceOver、Reduce Motion、Dynamic Type 和 High Contrast。
- Core / Platform / App 边界清晰，后台任务拥有明确的 actor、queue、lock 或 MainActor 所有权。
- Debug、Release、签名、公证和 Gatekeeper 流程分别有可重复的验证证据。

### Definition of Done

- [ ] 所有 P1 代码问题关闭并有回归测试。
- [ ] P2 问题完成，或在 issue 中记录明确的延期理由和替代保护措施。
- [ ] `swift test --package-path MacClippyKit` 通过。
- [ ] strict concurrency、package TSan、scale test、lifecycle stress test 通过。
- [ ] App build、App XCTest 和 App TSan 在兼容的 macOS/Xcode 环境通过。
- [ ] SwiftLint changed-file gate 无新增 violation。
- [ ] 10,000 / 100,000 条历史夹具下搜索结果正确，内存和响应时间有基线。
- [ ] 搜索、Preview、横向滑动和 Dock animation 有 Instruments / signpost 证据。
- [ ] Accessibility、TCC、Developer ID、Notarization、Gatekeeper 在真实环境完成验证。
- [ ] 没有把当前环境无法执行的 release-only 检查误报为已通过。

## 2. 当前基线

已存在并应保留：

- OCR lifecycle generation/token、active/pending budget 和停止时取消。
- disabled Snippet 不安装 event tap。
- SQLite ID 查询按 500 条批处理。
- structured search 分页和 early exit。
- Thumbnail cache、后台解码和 downsample。
- Dock outside click close、Settings fallback window 清理。
- `MacClippyDockModel` 的 `@MainActor` 隔离。
- Reduce Motion、键盘导航、Command+A 全量选择、storage health 和 FTS repair。

当前验证基线：

- Package tests：254 passed，3 skipped。
- SwiftLint：158 files，0 violations。
- Metadata verifier：Debug App 通过。
- Debug build、100,000-record scale test、lifecycle stress test 和 package TSan 已有通过记录。
- App XCTest 受当前本机 Xcode/CoreSimulator/LaunchServices 环境阻塞，不能视为已通过。
- Developer ID、Notarization、Gatekeeper、真实 TCC、VoiceOver、High Contrast、Instruments 和 soak test 尚无证据。

## 3. 优先级与依赖

| 优先级 | 工作流 | 主要风险 | 依赖 |
|---|---|---|---|
| P1 | Pasteboard safety | 失败时清空用户剪贴板 | 无 |
| P1 | Search correctness | Pinboard 漏搜、FTS 漏项/重复 | 先定义 cursor contract |
| P1 | Release verifier | notarization 后 DMG 验证失败 | 无真实证书也可先修脚本 |
| P2 | Error recovery | 错误被覆盖、分页静默停止 | P1 搜索状态模型 |
| P2 | Lock/concurrency | 搜索阻塞 capture/stop，潜在 data race | 先画状态所有权 |
| P2 | Accessibility | 大字号、高对比度和 VoiceOver 缺口 | UI 状态模型稳定后 |
| P2/P3 | Rendering performance | 横向滑动卡顿、重复重绘、图标浪费 | 需要 profiling baseline |
| P3 | Architecture split | 大文件修改风险高 | 行为测试先完善 |
| Release gate | CI / signing / notarization | 无法形成可发布证据 | Developer ID 和真实 TCC |

## 4. 分阶段实施计划

### Phase 0 — 建立安全基线

状态：`pending`

任务：

- [ ] 保留当前 worktree dirty changes，不执行 reset、clean 或覆盖用户修改。
- [ ] 记录当前 commit、Xcode、Swift、xcodegen、SwiftLint 版本。
- [ ] 运行 package tests、lint、Debug build、metadata verifier。
- [ ] 建立 10,000 / 100,000 条历史夹具和性能结果目录。
- [ ] 为每个后续 PR 规定：功能测试、错误路径测试、取消测试和性能回归测试。

验收：

- baseline 可重复执行。
- 任何后续失败都能区分为代码回归、环境问题或夹具问题。

### Phase 1 — P1 Pasteboard 数据安全

涉及：

- `MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardPreparation.swift`
- `MacClippy/MacClippyRuntime+ClipboardActions.swift`
- `MacClippy/MacClippyDockModel+Utilities.swift`

任务：

- [ ] Copy 前创建完整 pasteboard snapshot。
- [ ] snapshot 不完整时不执行 destructive clear。
- [ ] 任一写入失败时恢复原 pasteboard。
- [ ] 将 `Bool` 失败转换为 typed error 或明确的 throwing API。
- [ ] 修复成功 toast 误报。
- [ ] 保持自动 Paste 的既有恢复和 sentinel 行为。

测试：

- [ ] 写入失败后原始 text、image、URL 和多 representation 均恢复。
- [ ] snapshot 不可用时用户原剪贴板不被清空。
- [ ] Copy 返回 false 时不显示成功反馈。
- [ ] Pasteboard 并发/取消不会覆盖其他 App 的新剪贴板内容。

完成标准：Copy 的任何可恢复失败都不能造成用户剪贴板数据丢失。

### Phase 2 — P1 Search / Pagination Correctness

涉及：

- `MacClippy/MacClippyRuntime+History.swift`
- `MacClippy/MacClippyRuntime+HistoryPagination.swift`
- `MacClippy/MacClippyRuntime+Search.swift`
- `MacClippyKit/Sources/MacClippyCore/SearchStore.swift`
- `MacClippy/MacClippyDockModel+LoadingPreview.swift`
- `MacClippy/MacClippyDockModel+Selection.swift`

任务 A：Pinboard 搜索

- [ ] 把 Pinboard 搜索下沉到 Runtime / Store 分页查询。
- [ ] 或实现 query-specific continuation，持续扫描未加载页面。
- [ ] 搜索结果不依赖当前已经显示的数组。
- [ ] 为每个 query 保存 continuation、hasMore 和 error。

任务 B：FTS 稳定 continuation

- [ ] 定义 search token：query、sort、index revision、last stable ID。
- [ ] 去除依赖易变排序结果的裸 OFFSET。
- [ ] index revision 变化时使旧 token 失效并重新搜索。
- [ ] 保留 FTS rank 顺序和现有 structured predicate 语义。

测试：

- [ ] 匹配项只存在于 Pinboard 后续页面时可以搜索到。
- [ ] 搜索过程中 capture、OCR、label update 不会造成重复或漏项。
- [ ] 10,000 条和 100,000 条记录结果数量正确。
- [ ] 取消搜索后没有继续发送 UI 更新。
- [ ] page failure 保留 retry continuation。

完成标准：搜索所有逻辑数据，而不是只搜索当前已加载的 card。

### Phase 3 — P2 错误模型与恢复路径

涉及：

- `MacClippy/MacClippyDockModel.swift`
- `MacClippy/MacClippyDockView+CarouselModal.swift`
- `MacClippy/MacClippyDockModel+HistoryPagination.swift`
- `MacClippy/MacClippyDockModel+Selection.swift`
- 所有 Runtime action / preview / transform 调用方

任务：

- [ ] 拆分 `historyLoadError`、`pageError`、`previewError`、`actionError`。
- [ ] Retry 与具体失败操作绑定，不再统一调用 `reload()`。
- [ ] 保留 last successful snapshot，避免一次 action 错误覆盖整个 carousel。
- [ ] 分页失败显示 footer error 和 Retry。
- [ ] Pinboard 分页失败不再静默 return。
- [ ] 区分 storage error、permission error、corrupt record、missing record 和 user input error。
- [ ] 继续禁止日志写入 clipboard body、OCR text、文件名、绝对路径和敏感 query。

测试：

- [ ] Copy 失败只显示 action error，历史内容仍可用。
- [ ] Preview 失败只影响 preview，不清空 carousel。
- [ ] 第 N 页失败可单独 Retry。
- [ ] 损坏单条记录被跳过并记录脱敏诊断。
- [ ] 数据库连接/SQL/I/O 错误向上抛出，不伪装成空历史。

### Phase 4 — P2 并发、锁和生命周期

涉及：

- `MacClippy/MacClippyRuntime+Search.swift`
- `MacClippy/MacClippyRuntime+HistoryPagination.swift`
- `MacClippy/MacClippyRuntime+OCR.swift`
- `MacClippy/MacClippyRuntime+Lifecycle.swift`
- retention preference 读写路径

任务：

- [ ] 绘制 Runtime 状态所有权表：MainActor、actor、serial queue、lock。
- [ ] 缩短 `storeLock` 范围：锁内只做有界读取，解密和 DTO 构造移到锁外。
- [ ] 检查 lock 顺序，保证 search / capture / paste / stop 不形成死锁或长时间互相等待。
- [ ] 将 retention preferences 收敛到单一 serial owner 或 actor。
- [ ] 所有长期 Task 检查 `Task.isCancelled` 和 lifecycle token。
- [ ] 逐步减少 `Task.detached` 和 `@unchecked Sendable` 范围，并为必要边界添加说明。
- [ ] OCR metadata 与 FTS projection 使用同事务提交，或实现可靠 pending projection replay。

测试：

- [ ] start → schedule OCR → stop 不写入数据库。
- [ ] stop → start 后旧 generation 不污染新 Runtime。
- [ ] search/capture/stop 并发压力测试无死锁、无 TSan 报告。
- [ ] retention preference 并发读写无 data race。
- [ ] OCR 失败、取消、损坏输入都能释放 active/pending budget。

### Phase 5 — P2 Accessibility 与交互一致性

涉及：

- `MacClippy/MacClippyDockCard.swift`
- `MacClippy/MacClippyDockPreview.swift`
- `MacClippy/MacClippyDockPreviewSupport.swift`
- `MacClippy/MacClippyDockTheme.swift`
- `MacClippy/MacClippyDockPolicies.swift`
- `MacClippy/MacClippySettings+Sections.swift`

任务：

- [ ] 为 loading 增加 VoiceOver label：history、preview、image。
- [ ] 为 card 增加 Preview accessibility action。
- [ ] 搜索结果变化提供适度 accessibility announcement。
- [ ] 检查所有 card action 的 label、hint、selected state 和 focus return path。
- [ ] 引入 Dynamic Type-aware 字体和可伸缩 card 高度。
- [ ] 对 Settings 固定宽度控件增加最小可用空间和换行策略。
- [ ] 增加 `accessibilityContrast` / `differentiateWithoutColor` 适配。
- [ ] 选中、drop、error 状态不能只依靠颜色表达。
- [ ] 重新评估隐藏横向 scroll indicator 后的发现性，补充 edge fade 或键盘提示。

测试：

- [ ] VoiceOver 可完成搜索、选择、Preview、Copy、Paste、Delete、返回。
- [ ] Reduce Motion 下没有 offset、scale、stagger 或残留透明层。
- [ ] 大字号下 card、action bar、Settings 不截断主要操作。
- [ ] Light、Dark、High Contrast 和不同 accent 下状态可辨识。

### Phase 6 — P2/P3 Performance 与动画优化

任务 A：先测量

- [ ] 为 Dock open、search keystroke、card scroll、Preview open、Copy/Paste 加 `os_signpost`。
- [ ] 使用 Time Profiler、Allocations、Leaks、Core Animation、Energy Log。
- [ ] 记录主线程耗时、每帧 hitch、峰值内存、thumbnail 解码时间和数据库锁等待时间。

任务 B：横向滑动和渲染

- [ ] 将 card 依赖从完整 ObservableObject 缩小为 value-based props 或细粒度 observable state。
- [ ] 对 card 使用 Equatable 更新策略，避免无关 `@Published` 触发全部卡片重算。
- [ ] 保持 thumbnail 后台解码和尺寸上限。
- [ ] 增加 file icon waiter cancellation，最后一个 waiter 取消时终止 producer。
- [ ] 检查 Preview 大图的 128 MB 读取上限和解密峰值。
- [ ] 维护扫描从 OFFSET 改为 keyset cursor 或稳定 snapshot。

任务 C：动画收口

- [ ] 只保留 Dock entrance/exit、selection/focus、search/preview transition、action toast 四类动画。
- [ ] 只动画 opacity、transform 和窗口位置。
- [ ] 不增加 bounce、elastic、过多 stagger 或 layout animation。
- [ ] 验证 animation completion 都有 generation guard。
- [ ] 确保 animation 期间键盘操作不被阻塞。

性能验收：

- [ ] Dock 打开主线程不执行数据库读取或大图解码。
- [ ] 16 张可见 card 不会触发全量历史 body 解密。
- [ ] 搜索输入保持可感知的快速响应。
- [ ] 目标设备上没有明显 scroll hitch，接近 60fps。
- [ ] 长时间运行没有 pending task、event tap、monitor 或 cache 持续增长。

### Phase 7 — Architecture 拆分

原则：先用测试锁定行为，再拆文件；不在结构拆分阶段混入产品行为变化。

拆分顺序：

1. `MacClippyRuntime.swift`
   - Lifecycle
   - History / pagination
   - Search
   - Clipboard actions
   - OCR
   - Maintenance
2. `MacClippyDockCard.swift`
   - Card content
   - Card actions
   - Accessibility
   - Thumbnail / source icon
3. `MacClippyDockController`
   - Panel lifecycle
   - Event monitors
   - Preview coordination
   - Feedback / toast
   - Animation generation guard
4. `MacClippySettings`
   - Typed preferences
   - Settings sections
   - Permission status
   - Window coordinator
   - Presentation policy
5. `ClipboardStore.swift`
   - Batch reads
   - Search projection
   - Blob references
   - Deletion journal
   - Retention queries

验收：

- [ ] Core 不依赖 SwiftUI、AppKit、CGEvent 或 Vision UI。
- [ ] App 层仍通过 Runtime façade 使用现有 API。
- [ ] 每次拆分前后 package tests、App build 和关键行为测试一致。
- [ ] 不因为文件变小而增加单一调用的过度 protocol 抽象。

### Phase 8 — Tests、CI 与 Release Gate

新增单元测试：

- [ ] pasteboard snapshot / restore。
- [ ] Pinboard query pagination。
- [ ] stable FTS continuation 和 index revision。
- [ ] error state separation 和 page retry。
- [ ] OCR cancellation / restart isolation。
- [ ] store lock cancellation。
- [ ] Dynamic Type / motion policy / accessibility action。
- [ ] file icon waiter cancellation。

新增 App XCTest：

- [ ] App launch / shutdown。
- [ ] Dock show / hide / reopen。
- [ ] outside click close。
- [ ] Settings bring-to-front 和 fallback window 清理。
- [ ] presentation policy 四种组合。
- [ ] search focus、Preview、Details、Modal 键盘行为。
- [ ] Command+A 选择全部逻辑记录，而不只是当前可见 card。
- [ ] Copy / Paste / queue paste 成功与降级路径。
- [ ] Snippet permission transitions。

CI 顺序：

1. `xcodegen generate`
2. generated project clean check
3. SwiftLint baseline / changed-file gate
4. Package tests
5. Strict concurrency tests
6. Scale tests
7. Lifecycle stress tests
8. Package TSan
9. App TSan
10. Debug App build and App XCTest
11. Swift 6 warnings-as-errors build-for-testing
12. Release compile with Hardened Runtime
13. Metadata verifier
14. Sign / notarize / staple / Gatekeeper release gate

### Phase 9 — 发布验证

需要真实 Developer ID、Team ID、Notary profile 和真实设备。

- [ ] `codesign --verify --deep --strict`。
- [ ] Hardened Runtime enabled。
- [ ] Release entitlements 不含 `get-task-allow`。
- [ ] DMG root 只有一个 `MacClippy.app`。
- [ ] `xcrun notarytool submit --wait`。
- [ ] `xcrun stapler staple` 和 `stapler validate`。
- [ ] `spctl --assess --type open` / `execute`。
- [ ] Accessibility、Input Monitoring、Keychain、NSPasteboard 真实 TCC 验证。
- [ ] 升级安装覆盖旧版本并保留数据库、Keychain 和用户设置。
- [ ] 长时间运行 soak test。

## 5. 关键设计约束

### 并发

- 新代码优先 structured concurrency。
- 禁止用 `DispatchGroup.wait()` 等待 async 工作。
- 所有可取消任务同时检查 cancellation 和 lifecycle generation。
- 后台任务不得直接修改 `@Published` UI 状态。
- 所有 public API 明确线程、Sendable 和错误语义。

### 错误处理

- 基础设施错误不能使用无上下文的 `try?` 隐藏。
- 单条损坏记录可以跳过，但必须记录脱敏诊断。
- 数据库、I/O、Keychain、权限、用户输入和缺失记录必须使用不同 recovery path。
- 不在日志、Toast、VoiceOver label 中泄露完整 clipboard body 或 OCR 文本。

### 性能

- 不在主线程执行数据库读取、大图解码或大批量解密。
- 不使用 `.max` materialize 全量 history。
- 不使用无界 `IN (...)`。
- 优先优化可测量的锁等待、重绘、内存峰值和滚动 hitch。
- 不为了微优化引入难以维护的抽象。

## 6. 风险与回滚策略

| 风险 | 保护措施 |
|---|---|
| Search cursor 改动导致排序变化 | 保留旧查询路径作为测试 oracle，先做对比测试 |
| Pasteboard restore 覆盖用户新复制内容 | 使用 write sentinel / change count 校验 |
| 锁范围缩短导致 snapshot 不一致 | 引入 generation/version 校验，不延长全局锁 |
| Card 拆分改变 SwiftUI identity | 先固定 stable ID 和 snapshot tests |
| Accessibility 修复破坏键盘焦点 | App XCTest 覆盖焦点进入和返回路径 |
| Release 脚本在无证书环境不可验证 | Debug metadata 与 signed release gate 分开报告 |

## 7. 推荐 PR 切分

1. `fix/pasteboard-transaction-safety`
2. `fix/search-pagination-correctness`
3. `fix/dmg-team-id-verification`
4. `refactor/error-state-recovery`
5. `refactor/runtime-lock-boundaries`
6. `a11y/dynamic-type-and-voiceover`
7. `perf/card-rendering-and-scroll`
8. `refactor/runtime-and-store-boundaries`
9. `test/app-xctest-coverage`
10. `release/signing-notarization-gates`

每个 PR 必须保持范围单一，并附：变更说明、测试命令、失败路径、性能影响和未覆盖环境限制。

## 8. 最终执行顺序

```text
Baseline
  -> Pasteboard safety
  -> Pinboard / FTS correctness
  -> DMG verifier
  -> Error state and retry
  -> Lock / lifecycle hardening
  -> Accessibility
  -> Performance profiling and scroll optimization
  -> Architecture split
  -> App XCTest / CI gates
  -> Signing / notarization / Gatekeeper
```

不要在完成 P1 数据安全和搜索正确性之前进行大规模文件重构，也不要用 Debug build、package tests 或静态 plist 检查替代真实签名、公证、TCC 和 Gatekeeper 证据。

# Goal: MacClippy 从 Advanced Beta 到 Production-Ready

> 这是一份给 Codex 执行的工程 Goal。后续每次让 Codex 改进 MacClippy 时，先读取本文件，再按优先级推进；不要把它当成普通产品建议清单。

## 1. 总目标

将 `mac-clippy/` 从当前的 advanced beta 提升到可以公开分发、长期稳定运行的 macOS 原生剪贴板管理器。

最终用户应该能够：

- 安全地捕获、搜索、预览、复制和粘贴文本、富文本、图片、文件 URL 等内容；
- 在普通 App、Terminal、浏览器、Electron、远程桌面、非 QWERTY 键盘和多显示器环境中稳定使用；
- 在应用异常退出、数据库损坏、迁移失败、权限变化或单条记录异常时恢复历史，而不是静默丢失数据；
- 清楚知道哪些数据会被捕获、保存在哪里、如何暂停、排除和删除；
- 通过签名、公证、更新和权限流程安装，不因 ad-hoc 签名反复丢失 Accessibility 或 Keychain 信任；
- 在没有明显卡顿、内存失控、后台高 CPU、UI 卡死或可复现崩溃的情况下长期运行。

## 2. 当前基线与判断

当前判断：**功能基础很强，但还不是 public-production-ready。**

已验证的基线：

- `MacClippyKit`：179 个测试通过，0 failed；
- App XCTest：114 个测试通过，0 failed，0 skipped；
- 当前 Debug 产物仍是 ad-hoc/linker-signed，没有 Developer ID、notarization、stapling 和干净机器 Gatekeeper 验证证据；
- 现有核心能力包括多 representation 捕获、GRDB 存储、加密图片 blob、FTS 搜索、OCR、pinboard、批量操作、queue paste、transform、全局快捷键和底部 dock；
- 自动化测试覆盖了大量纯策略和业务逻辑，但还不能代替真实 TCC 权限、Keychain、Accessibility、pasteboard lazy provider、CGEvent、签名安装和长时间运行测试。

因此，本 Goal 的重点顺序是：

1. 数据安全与恢复；
2. pasteboard 输入边界与并发稳定性；
3. 权限、签名、公证、CI 和可观测性；
4. paste 可靠性和跨 App 行为；
5. UX polish 与差异化功能。

## 3. 架构决策：暂不迁移到 Tauri

### 决策

继续使用 **Swift + AppKit + SwiftUI**，不做整体 Tauri rewrite。

### 原因

- MacClippy 是 macOS-first 工具，核心价值依赖 `NSPasteboard`、Accessibility、CGEvent、全局快捷键、NSPanel、菜单栏生命周期、TCC 和 Keychain；
- Swift/AppKit 对这些能力的权限、事件、焦点、窗口和系统行为有最短路径，现有代码已经建立了大量原生基础；
- Tauri 会增加 WebView、Rust command bridge、前端状态和原生权限边界，但不会自动解决签名、公证、TCC、pasteboard 数据损坏、内存上限或崩溃问题；
- PasteBar 的 Tauri/Rust 架构适合作为跨平台和 UI 分层参考，但不证明 Tauri 是 macOS 稳定性的捷径；
- 现在迁移会把产品风险从“修复可靠性”扩大为“重写全部核心行为”。

### 只有在以下条件成立时才重新评估 Tauri

- Windows/Linux 成为明确、已承诺的产品交付目标；
- 已先抽出有稳定测试覆盖的平台无关 domain model；
- 团队愿意维护 Rust、WebView、前端 UI 和 Swift 原生桥接四个边界；
- 通过小型原型证明跨平台收益足以抵消原生能力和维护复杂度损失。

在这些条件成立之前，不要为了“跨平台可能性”创建 Tauri 分支、迁移核心存储或重写 picker。

## 4. Codex 执行契约

每次执行本 Goal 时都必须遵守以下规则：

### 范围

- 只修改 `mac-clippy/`，除非用户明确要求扩大范围；
- 保留工作区已有 dirty changes，不使用 `git reset --hard`、`git checkout --` 或广泛删除；
- 先检查当前 diff、相关源文件、测试和 `project.yml`，再动手；
- 不要顺手重构无关代码，不要为了“更干净”删除已有功能或文件；
- 不要把同步、云端账户、AI 自动化、Windows/Linux 支持或 Tauri rewrite 混入本 Goal。

### 实现方式

- 先写能够复现问题的最小测试，再写最小修复；如果无法自动化，写明确的手工验收步骤和证据要求；
- 优先使用现有 `MacClippyCore`、`MacClippyPlatform`、GRDB、AppKit/SwiftUI 和现有 policy 类型；
- 新增 UI 必须遵循现有 MacClippy 的 motion、颜色、间距、焦点和 Reduce Motion 规则；
- 所有异步路径都要明确线程/actor/队列、取消、超时、错误传播和生命周期；
- 任何包含剪贴板内容的日志、测试输出、崩溃上下文和诊断包都必须脱敏；
- 不把“日志记录了错误”当成“功能正确”。错误必须有用户可理解的状态、恢复路径或明确的降级行为。

### 每个阶段的工作循环

1. 读取本文件、现有 `task_plan.md`、`findings.md` 和最近的 `progress.md`；
2. 说明本阶段的假设、目标文件和验证标准；
3. 先增加回归测试或测试夹具；
4. 做最小实现；
5. 运行最窄的测试，再运行完整 package/app 测试；
6. 做静态检查、构建和必要的手工验证；
7. 在 progress 中记录命令、结果、环境限制和未解决风险；
8. 只有满足验收标准才能勾选任务；失败不能隐藏，连续三次同一阻塞应停止并报告具体 blocker。

## 5. 成功标准

### 5.1 发布和安装

- Release 构建使用稳定的 Developer ID 签名；
- 主 App、Login Item、相关 extension 的 entitlements 和 Hardened Runtime 经过审核；
- notarization、stapling、Gatekeeper 验证在干净用户环境通过；
- 首次安装、更新、降级/回滚、卸载、重新安装都能正确处理权限和数据；
- CI 能从干净环境完成生成、测试、Release build、签名/公证所需的验证步骤；
- 发布说明、隐私说明、权限用途、诊断导出和恢复说明与实际行为一致。

### 5.2 数据完整性

- 每次启动能检测数据库可读性、schema 版本、关键表、FTS 和 blob 引用；
- `quick_check`、备份、恢复、迁移回滚和 FTS rebuild 有明确 API、命令或诊断入口；
- 父记录、representation 行、blob 文件和 FTS 行不会出现静默半成功；
- retention、批量删除和 blob 清理支持中断后重试，不能因 force quit 永久留下无法解释的状态；
- 备份恢复演练能够恢复文本、富文本、图片、文件 URL、标签、pinboard 和搜索能力；
- 单条损坏记录不会阻止整个历史加载，也不会导致 UI 报告虚假的“全部成功”。

### 5.3 输入、内存和并发

- 单个 UTI、单次 pasteboard event、单条记录和总历史都有可解释的大小上限；
- oversized、malformed、unknown UTI、lazy provider 超时和空 payload 都有确定行为；
- pasteboard changeCount、observer timer、provider reread 和 generation 状态由一个可证明的生命周期执行器串行管理；
- 所有 `@unchecked Sendable` 都有明确理由、隔离边界和测试；能移除的必须移除；
- 数据库、blob、FTS、UI reload 和后台任务之间没有竞态导致崩溃、重复记录或 UI stale state；
- 通过压力夹具验证长时间复制、快速连续复制、超大内容、图片、文件和 lazy provider 场景不会无限增长内存。

### 5.4 隐私和权限

- 默认过滤 concealed、transient、auto-generated 和明确不应保存的 pasteboard 数据；
- “Capture All” 是用户主动开启的、带风险说明的高级选项，而不是默认模式；
- app exclusions、暂停捕获、清空历史、按条删除和 retention 设置真实生效；
- Accessibility、Input Monitoring、Keychain 等权限缺失时，用户看到明确的原因、设置入口和可用 fallback；
- 日志和诊断不包含 clipboard body、图片、OCR 全文、token、密码或隐私 app 的敏感内容；
- 权限被撤销、应用签名变化或系统升级后，功能能降级并显示状态，不循环重试或卡死。

### 5.5 粘贴可靠性

- 常见原生 App、Terminal、浏览器、Electron、远程桌面和非 QWERTY 键盘都有手工/自动化覆盖；
- Accessibility 可用时，paste injection 只在确认注入成功后更新 frequency 和 UI 状态；
- Accessibility 不可用时，清楚显示 manual paste，不得声称已经粘贴；
- paste 失败时恢复用户原来的系统 clipboard，或明确说明无法恢复并避免覆盖；
- queue paste、multi-paste、transform paste 在部分失败、目标 App 消失、权限变化和用户取消时不产生静默丢失；
- 全局快捷键注册、更新、冲突、注销和 app 退出都具备回滚和清理行为。

### 5.6 可观测性和稳定性

- 使用结构化 `OSLog`/统一 logger，记录生命周期、失败类别、耗时和恢复动作，不记录原文；
- 崩溃和异常报告可以区分 capture、storage、FTS、paste、permission、hotkey 和 UI lifecycle；
- diagnostics 能导出版本、签名、权限状态、数据库健康摘要、最近错误计数和配置摘要；
- 诊断导出可被用户安全分享，默认不包含剪贴板正文；
- 对启动恢复、capture latency、search latency、paste latency、数据库错误和内存峰值有最基本指标；
- 长时间运行、休眠唤醒、显示器变化、App 重启和异常退出后没有可复现崩溃。

## 6. 分阶段实施路线

### Phase 0 — Baseline、范围和复现

目标：固定当前行为，避免后续修复误伤已有能力。

- [ ] 检查 `git status` 和 `git diff`，记录已有 dirty changes，确认只在 `mac-clippy/` 工作；
- [ ] 运行并记录当前基线：
  - `cd mac-clippy`
  - `make generate`
  - `swift test --package-path MacClippyKit`
  - `xcodebuild -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -arch arm64 build`
  - `xcodebuild test -project MacClippy.xcodeproj -scheme MacClippy -configuration Debug -destination 'platform=macOS,arch=arm64'`
- [ ] 建立一个 release-readiness checklist，所有后续任务都必须附测试证据或明确的手工证据；
- [ ] 先确认现有行为：`⌘⇧V`、首次打开 picker、搜索、预览、复制、粘贴、queue paste、pinboard、清空、暂停和重启。

完成标准：基线测试结果已写入 `mac-clippy/progress.md`，任何失败都有分类和下一步，不把环境问题误报为产品失败。

### Phase P0-A — Release、签名、公证和 CI

目标：让“可安装、可更新、可被系统信任”成为可验证事实。

建议起点：`mac-clippy/project.yml`、`mac-clippy/Makefile`、`mac-clippy/MacClippy/MacClippy.entitlements`、`mac-clippy/MacClippy/Info.plist`。

- [ ] 分离 Debug 与 Release 的签名策略；Debug 可以保持本地开发便利，但 Release 不能依赖 `CODE_SIGNING_ALLOWED=NO`；
- [ ] 明确主 App、Login Item、extension 的 bundle identifier、TeamIdentifier、entitlements 和 Hardened Runtime；
- [ ] 检查 `disable-library-validation` 等 entitlement 是否必要、是否只应用于真正需要的 target；
- [ ] 增加 Release archive、签名验证、公证提交、staple 和 Gatekeeper 验证脚本；
- [ ] 为签名证书、notary credentials、app-specific password/API key 设置 CI secret 边界，不把凭据写入仓库；
- [ ] CI 至少覆盖 project generation、package tests、app tests、Release compile、签名检查和产物元数据检查；
- [ ] 对新安装、更新安装、旧版本迁移和签名变化做真实 TCC/Keychain 手工矩阵；
- [ ] 记录 `codesign --verify --deep --strict`、`spctl --assess`、`notarytool`、`stapler` 的成功证据。

验收：能在干净用户环境安装并打开；Accessibility/Keychain 不会因为 ad-hoc 身份变化而反复失效；发布包不是“本地能运行但无法信任”的 Debug 产物。

### Phase P0-B — 数据库健康、备份、恢复和 FTS 修复

目标：任何数据库问题都能被发现、解释和恢复，不能静默丢历史。

建议起点：

- `mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyCore/SearchStore.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyCore/BlobStore.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyCore/MacClippyReconciliation.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyCore/RetentionPolicy.swift`

- [ ] 启动时执行轻量 schema/version/关键表健康检查；
- [ ] 增加 SQLite `quick_check` 或等价健康检查，并把结果区分为 healthy、degraded、repairable、unrecoverable；
- [ ] 增加一致性备份流程：数据库、blob、版本、校验摘要必须形成同一份可恢复快照；
- [ ] 增加 restore 到临时目录的验证流程，验证记录数、representation 数、blob 引用、FTS 可搜索性和 pinboard 关系；
- [ ] 对 migration 失败提供备份恢复或向后兼容回滚策略，不能只留下半迁移数据库；
- [ ] 增加 FTS rebuild/repair：发现父记录存在但索引缺失时可重建，重建过程可取消、可重试；
- [ ] 增加 blob orphan、missing blob、missing representation 和 dangling FTS row 的诊断摘要与修复策略；
- [ ] 为 retention、batch delete、blob 删除增加 deletion journal 或等价的可重试状态；
- [ ] 将“主记录已保存但 FTS 失败”的情况变成明确的 degraded/repairable 状态，不允许只 `log` 后当作完全成功；
- [ ] 为 force quit、进程被 kill、磁盘空间不足、数据库锁、损坏 blob 和恢复中断增加测试。

验收：故意制造缺失 FTS、孤立 blob、未完成删除和中断迁移后，启动诊断能识别问题，并能通过 repair/restore 恢复可搜索历史。

### Phase P0-C — Pasteboard 输入边界和安全默认值

目标：把系统 pasteboard 当作不可信、可能超大、可能延迟、可能 malformed 的输入。

建议起点：

- `mac-clippy/MacClippyKit/Sources/MacClippyPlatform/PasteboardCapture.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyPlatform/PasteboardMapping.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardReadRetry.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteboardReadRetryState.swift`
- `mac-clippy/MacClippy/MacClippyRuntime.swift`

- [ ] 定义并集中管理单个 representation、单个 change、单条记录和历史总量的大小上限；
- [ ] 评估 `data(forType:)` 的 materialization 风险；在 API 无法流式读取时，至少限制保留、转换、写入和并发任务数量，并测试超大输入；
- [ ] 对 unknown UTI、空数据、malformed RTF/HTML、无效文件 URL、损坏图片和 provider unavailable 定义稳定结果；
- [ ] 防止同一 pasteboard change 被重复读取、重复写入或在 generation 变化后把旧 provider 数据写入新记录；
- [ ] 将 lazy-provider reread 绑定到原始 `changeCount`/generation，发现系统 pasteboard 已变化时必须放弃旧 reread；
- [ ] 默认过滤 concealed、transient、auto-generated 和明确不应持久化的类型；
- [ ] 提供用户可理解的 Capture All 高级开关、风险说明和状态；
- [ ] 保留 app exclusions、pause capture 和临时暂停的明确优先级；
- [ ] 为密码管理器、支付内容、一次性验证码、浏览器内部标记、连续复制、lazy provider 和超大 payload 增加夹具；
- [ ] 明确 capture 失败是跳过、保存 type-only marker、保存 partial record 还是显示 degraded，并让 UI 和日志一致。

验收：恶意/超大/延迟/未知输入不会导致无界内存增长、死循环、重复记录、旧 generation 污染或崩溃；默认行为对敏感内容是保守的。

### Phase P0-D — Crash-safe logging、诊断和恢复 UX

目标：出现问题时既不泄露内容，也不让用户只能“重启试试”。

- [ ] 统一 logger category：lifecycle、capture、storage、fts、blob、paste、hotkey、permission、ui；
- [ ] 所有错误记录稳定 error code、operation、duration、retry count、recovery action 和影响范围；
- [ ] 对 clipboard body、image bytes、OCR 文本、文件路径中的敏感部分使用 `.private`/摘要/哈希，默认不输出原文；
- [ ] 增加用户可触发的 diagnostics export，包含版本、签名、权限状态、数据库健康、计数和最近错误摘要；
- [ ] 增加 degraded state：数据库修复中、搜索索引需要修复、Accessibility 不可用、capture paused、hotkey unavailable；
- [ ] 为启动修复、恢复失败、权限失效、磁盘空间不足和 retention 失败提供清楚的 UI 操作；
- [ ] 崩溃后下一次启动不重复触发同一个失败任务，不阻塞 picker 打开。

验收：用户可以导出不含剪贴板正文的诊断包；开发者可以仅凭 error code 和摘要定位失败阶段；恢复失败有下一步行动。

### Phase P1-A — 并发、生命周期和 Sendable 收紧

目标：消除“偶尔 crash/偶尔 stale/偶尔重复”的竞态源。

- [ ] 审核 `MacClippyRuntime` 的 `@unchecked Sendable`，优先改为 actor、主 actor 或明确 serial executor；每个豁免都要有注释和测试理由；
- [ ] 将 `PasteboardObserver` 的 timer、handler、generation、lastChangeCount 和 invalidation 统一到一个 lifecycle executor；
- [ ] 保证 start/stop/restart/deinit/permission change 具有幂等性；
- [ ] 将 capture、store、FTS、OCR、thumbnail、UI reload 的 ownership 和取消关系写清楚；
- [ ] 检查 app 退出、dock 关闭、screen change、sleep/wake 和权限变化时后台任务是否仍会回调已释放对象；
- [ ] 用 Thread Sanitizer、主线程检查、连续 start/stop 压力测试和快速复制压力测试验证；
- [ ] 对数据库 connection、store lock 和跨队列 closure 做最小化隔离，避免用更大的锁掩盖设计问题。

验收：重复启动/停止 observer、快速复制、快速搜索/关闭 dock、休眠唤醒和退出重启压力测试无 data race、重复记录、死锁或回调已释放对象。

### Phase P1-B — Paste、快捷键和权限状态机

目标：把“粘贴失败”变成可恢复、可解释的结果。

建议起点：

- `mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector.swift`
- `mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyGlobalHotKey.swift`
- `mac-clippy/MacClippy/MacClippyApp.swift`
- `mac-clippy/MacClippy/MacClippyDock.swift`

- [ ] Paste 前保存系统 clipboard 的必要状态；注入失败、目标 App 消失、权限被撤销时按策略恢复或明确提示；
- [ ] 只有 confirmed injected 才增加 frequency、关闭 picker 或显示成功；manual paste、partial、cancelled 和 failed 必须分别建模；
- [ ] 验证文本、HTML/RTF、图片、文件 URL、queue paste、multi-paste 和 transform paste 的部分失败行为；
- [ ] 覆盖 Terminal、浏览器、Electron、远程桌面和非 QWERTY 键盘；保留必要的 QWERTY/keycode fallback，但不要假设所有键盘布局相同；
- [ ] 全局快捷键注册/更新失败时回滚 UI 设置，不能保存一个实际未注册的 shortcut；
- [ ] 应用退出、重复启动、快捷键冲突和权限撤销时安全注销 monitor/event tap/hotkey；
- [ ] `Launch at Login` 不使用静默 `try?` 吞掉错误；设置界面必须反映 `SMAppService.status` 和失败原因；
- [ ] Accessibility/Input Monitoring 缺失时保留可用的 copy/manual paste 路径，不要阻塞 capture/search。

验收：每一种 paste 结果都能被 UI、日志和测试区分；失败不会把用户 clipboard 静默覆盖，也不会报告虚假成功。

### Phase P1-C — Permission、首次运行和隐私 UX

- [ ] 首次运行用短流程解释 clipboard 数据、图片/blob、OCR、Keychain、Accessibility 和 Input Monitoring 的用途；
- [ ] 只在需要时请求权限，说明“为什么现在需要”，避免启动即弹多个系统对话框；
- [ ] 权限状态页显示 granted、denied、not requested、restricted、needs restart 等状态；
- [ ] 权限被撤销后有恢复按钮和设置深链；
- [ ] 明确“本地保存”不等于“绝对不会离开设备”，说明日志、导出、备份和未来网络能力的边界；
- [ ] Capture All、app exclusion 和清空历史提供确认、undo 或明确不可逆提示；
- [ ] 把密码、验证码、支付数据和私密窗口作为默认风险教育场景，而不是只写在 README。

验收：新用户无需阅读源码即可理解捕获范围、保存位置、暂停方式、删除方式和权限用途；权限缺失时仍能完成基础 copy/search。

### Phase P1-D — UX polish、性能和可访问性

目标：在稳定性完成后，把产品体验从“功能可用”提升到“每天愿意使用”。

- [ ] Picker 首次打开速度、搜索响应、preview 加载和 paste feedback 有可测 latency；
- [ ] 主线程不执行数据库查询、FTS、blob 解密、图片解码、OCR 或大 payload 转换；
- [ ] history、pinboard、search empty、loading、repairing、permission missing、manual paste 和 partial failure 都有清楚的状态；
- [ ] 键盘优先：打开 picker 后焦点确定、箭头/Enter/Space/Esc 行为一致，不能发出 prohibited-operation beep；
- [ ] 鼠标点击会同时更新 focus/selection/preview，避免用户看不出当前选中项；
- [ ] 多显示器、负坐标、屏幕变化、Dock/preview 边界和 Reduce Motion 都必须保持稳定；
- [ ] VoiceOver label、keyboard focus、对比度、动态字体/缩放和 Reduce Motion 做手工检查；
- [ ] 保持固定 panel geometry，避免无意义的尺寸跳动、过度动画、hover-only critical action 和视觉噪音；
- [ ] 对历史数量增大、长文本、图片缩略图和搜索结果做 Instruments/内存采样。

验收：关键路径在普通使用下无卡顿或焦点歧义；视觉反馈不会把 degraded/partial/manual 状态伪装成成功。

### Phase P2 — 差异化和长期产品方向

只有 P0/P1 完成并通过 release gate 后，才进入此阶段。

- [ ] 可信的本地历史：用户知道每条记录为什么被捕获、保存多久、如何恢复和彻底删除；
- [ ] 工作流 pinboard：项目/客户/任务拥有可检索、可排序、可批量粘贴的临时工作集；
- [ ] 可解释的 transform：输入、输出、失败和是否修改系统 clipboard 都明确；
- [ ] 搜索增强：`type:`、`app:`、`tag:`、`has:`、时间范围和 OCR 等结构化条件继续保持可修复、可解释；
- [ ] 自动化接口（CLI/MCP/Shortcuts）必须有权限、审批、超时、数据范围和审计边界，默认不执行任意脚本；
- [ ] 如果未来加入同步，先设计端到端加密、冲突、删除语义和离线恢复，再决定是否实施；
- [ ] 任何 AI/云端能力必须是显式 opt-in，不能改变本地 clipboard 的隐私默认值。

## 7. 测试与验证矩阵

### 自动化命令

在 `mac-clippy/` 执行，命令如因 Xcode/系统版本差异调整，必须把实际命令记录在 progress：

```sh
make generate
swift test --package-path MacClippyKit
xcodebuild -project MacClippy.xcodeproj \
  -scheme MacClippy \
  -configuration Debug \
  -arch arm64 build
xcodebuild test -project MacClippy.xcodeproj \
  -scheme MacClippy \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64'
```

Release gate 需要补充与当前 Makefile 不同的真实 Release 证据：

```sh
# 具体签名参数以本机证书和 CI secret 为准，不要把凭据写进仓库
xcodebuild archive ... -configuration Release
codesign --verify --deep --strict --verbose=2 <App-or-Archive>
spctl --assess --type execute --verbose=4 <App>
xcrun notarytool submit ... --wait
xcrun stapler validate <App-or-DMG>
```

### 自动化测试分类

- Core：模型、representation、search grammar、retention、reconciliation、migration、backup/restore；
- Platform：pasteboard mapping、payload limits、lazy provider generation、paste injector、hotkey policy、display layout；
- App：dock focus、picker keyboard flow、permission state、partial failure、transform、queue paste、settings persistence；
- Integration：真实 NSPasteboard、CGEvent/Accessibility、Keychain、SMAppService、Vision/OCR、休眠唤醒和签名身份；
- Soak：持续运行、快速复制、快速搜索、图片/大文本、频繁打开关闭 picker、sleep/wake、screen changes、force quit/relaunch。

### 必测手工矩阵

- 首次安装、升级、降级、卸载、重新安装；
- Developer ID 签名和 ad-hoc 签名对 Accessibility/Keychain 状态的区别；
- Accessibility granted/denied/revoked；Input Monitoring granted/denied；
- Terminal、Safari/Chrome、Electron、远程桌面、普通 App；
- US QWERTY、至少一种非 QWERTY 键盘；
- 单显示器、多显示器、负坐标、屏幕参数变化、休眠唤醒；
- 文本、空文本、HTML、RTF、PNG/TIFF、文件 URL、多个 representation、unknown UTI、lazy provider；
- Capture All 开关、app exclusion、暂停、retention、清空、按条删除、备份恢复；
- 数据库锁、磁盘空间不足、缺失 blob、缺失 FTS、迁移中断、应用 force quit。

## 8. 主要代码位置

优先从这些位置建立实现和测试映射，不要凭文件名猜架构：

- App composition/runtime：`mac-clippy/MacClippy/MacClippyRuntime.swift`、`mac-clippy/MacClippy/MacClippyApp.swift`；
- Dock/picker：`mac-clippy/MacClippy/MacClippyDock.swift`、`mac-clippy/MacClippy/MacClippyDockController.swift`、`mac-clippy/MacClippy/MacClippyDockPanel.swift`；
- Pasteboard：`mac-clippy/MacClippyKit/Sources/MacClippyPlatform/PasteboardCapture.swift`、`PasteboardMapping.swift`、`MacClippyPasteboardReadRetry.swift`；
- Paste/hotkey：`mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyPasteInjector.swift`、`MacClippyGlobalHotKey.swift`；
- Storage：`mac-clippy/MacClippyKit/Sources/MacClippyCore/ClipboardStore.swift`、`SearchStore.swift`、`BlobStore.swift`、`PathsDatabase.swift`；
- Recovery/retention：`mac-clippy/MacClippyKit/Sources/MacClippyCore/MacClippyReconciliation.swift`、`RetentionPolicy.swift`；
- Tests：`mac-clippy/MacClippyKit/Tests/`、`mac-clippy/MacClippyTests/`；
- Build/distribution：`mac-clippy/project.yml`、`mac-clippy/Makefile`、`mac-clippy/MacClippy/MacClippy.entitlements`、`mac-clippy/MacClippy/Info.plist`。

实际修改前必须确认文件仍存在、target 仍引用它、当前实现没有被后续 dirty changes 改写。

## 9. 竞品研究转化为工程要求

| 参考产品 | 可借鉴点 | 对 MacClippy 的要求 |
|---|---|---|
| [Paste](https://pasteapp.io/) | 快速 picker、预览、pinboard、跨设备产品信任 | 先做到本地快速检索、稳定 preview、清楚隐私边界；不盲目复制同步和订阅模式 |
| [Deck DeepWiki](https://deepwiki.com/yuzeguitarist/Deck) | Swift 原生、SQLite/blob、加密同步、CLI/MCP、修复和边界处理 | 借鉴 integrity-gated startup、bounded input、repairable migration、hotkey teardown、paste failure restore |
| [Maccy DeepWiki](https://deepwiki.com/p0deje/Maccy) | 原生 keyboard-first picker、changeCount、敏感类型过滤、键盘布局处理 | 默认过滤 concealed/transient/auto-generated；保持 picker 快速、键盘可预测 |
| [Clipy DeepWiki](https://deepwiki.com/Clipy/Clipy) | 原生 macOS、CI/release、权限和签名经验 | Developer ID 身份不是发布装饰，而是 Accessibility/Keychain 信任的一部分 |
| [PasteBarApp](https://github.com/PasteBar/PasteBarApp) | Tauri/Rust、local SQLite、collections/boards、lock/passcode | 作为跨平台架构和广度参考；不把 Tauri 当作稳定性捷径 |
| [CopyQ](https://github.com/hluk/CopyQ) | 跨平台、插件、脚本、自动化和长期维护 | 自动化必须有权限、超时、数据范围和审计；避免无边界脚本能力 |

## 10. Release Go / No-Go

### No-Go 条件

任一条件成立时，不发布 public production 版本，只做 private/advanced beta：

- 仍没有 Developer ID + notarization + Gatekeeper 的真实证据；
- 数据库无法 quick check、备份、恢复或修复 FTS；
- pasteboard 输入没有硬边界，或 lazy provider generation 仍可能污染新记录；
- 默认会捕获 concealed/transient/auto-generated 敏感内容且没有明确 opt-in；
- paste 失败仍会静默覆盖原 clipboard 或显示虚假成功；
- `@unchecked Sendable`、observer lifecycle 或后台 callback 仍存在未解释的 race/crash 风险；
- 权限、快捷键、Launch at Login 的失败仍被 `try?` 或 silent fallback 吞掉；
- 没有不泄露 clipboard 正文的 diagnostics 和 crash-safe logs；
- 关键 manual test matrix 未执行或结果不可复现。

### Go 条件

- P0 全部完成；
- P1 的并发、paste、权限、恢复和 UX 状态至少完成最小可发布范围；
- package/app 自动化测试无回归；
- Release artifact 在干净机器安装、更新、启动、授权、使用和卸载通过；
- 关键路径经过至少 24–72 小时 soak 或等价压力验证；
- 没有已知的可复现 crash、静默 data loss、权限死循环或虚假成功状态；
- README、隐私说明、设置文案、诊断和 release notes 与实现一致。

## 11. Definition of Done

只有满足以下全部条件，Codex 才能把本 Goal 标记为 complete：

- [ ] 代码、测试、配置和发布脚本已提交到 `mac-clippy/` 对应变更范围；
- [ ] P0 全部完成并有可复现证据；
- [ ] P1 中与 crash、data loss、权限、paste、并发和用户误解相关的项目全部完成；
- [ ] P2 可以延期，但每个延期项都有理由，不得把 P0/P1 偷换成未来计划；
- [ ] `MacClippyKit` package tests 通过；
- [ ] app XCTest 通过；
- [ ] Debug 和 Release 编译都通过；
- [ ] 签名、公证、staple、Gatekeeper 和 TCC 手工矩阵完成；
- [ ] 数据库损坏/中断/恢复演练完成；
- [ ] 大 payload、lazy provider、连续复制和长时间运行验证完成；
- [ ] diagnostics、日志、权限状态和失败反馈经过隐私检查；
- [ ] 结果写入 `mac-clippy/progress.md`，包含命令、版本、环境、测试数字和残余风险；
- [ ] 最终报告明确区分“已验证”“推断”“尚未验证”，不使用“应该稳定”代替证据。

## 12. 每次 Codex 继续执行时的开场模板

```text
我将继续执行 MacClippy-Prod-Readiness-Goal.md。

当前阶段：<Phase / Task ID>
本次目标：<一个可验证的目标>
范围：<将修改的文件/target>
不会做：<明确排除的工作，例如 Tauri rewrite、sync、无关 UI 重构>
验证：<先跑的测试、构建或手工检查>
风险/假设：<需要注意的环境或权限限制>
```

## 13. 当前建议的下一步

不要从 UX 新功能开始。下一次 Codex 执行应从 **Phase 0** 开始，然后优先处理：

1. P0-A：Release signing、Hardened Runtime、notarization 和 CI 骨架；
2. P0-B：SQLite health check、backup/restore、FTS repair 和 deletion journal；
3. P0-C：pasteboard payload 上限、lazy-provider generation 和隐私安全默认值；
4. P0-D：脱敏结构化日志、diagnostics 和 degraded/recovery UX；
5. P1-A/P1-B：并发生命周期、paste failure restore、hotkey rollback 和 Launch at Login 错误处理。

Tauri 迁移不属于当前执行队列。

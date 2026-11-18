# MacClippy UI 与操作流程独立终审

审查日期：2026-10-14。审查者：workflow_review。结论：**当前源码没有发现尚未修复的确定 P1／P2。** 前轮确认问题均已按真实调用链闭环；本轮工程代理确认的 New Pinboard 提交／迟到回调问题也已核实修复。该结论是源码与现有证据范围内的结论，不等于所有原生环境和视觉组合都已验收。

本审查没有修改仓库文件、操作 GUI 或运行测试。只读审查了当前实现、组合增量、测试代码、已有执行日志和原始验收记录。本文是唯一新写入的文件。用户明确取消 VoiceOver 和跨机器迁移，本报告不将它们列为缺陷或验收缺口。保存搜索、新逐项队列、Undo、OCR 调度不扩展进本轮。

## 版本与证据绑定

- 当前组合变更：[64 路径列表](/tmp/macclippy-cua-pinboard-final-review-files.json)、[完整组合补丁](/tmp/macclippy-cua-pinboard-final-review.patch)。New Pinboard 单独补丁：[pinboard delta](/tmp/macclippy-pinboard-review-fix.patch)。
- repair 基线见 [baseline 指针](/tmp/macclippy-review-fix-baseline.json)；本轮原生修复基线为 /tmp/macclippy-cua-fix-baseline。审查以这些增量和当前工作树为准，未把用户原有大量未提交改动全归为本轮。
- 当前源码 manifest：[pinboard final manifest](/tmp/macclippy-cua-pinboard-final-manifest.json)，SHA256 为 **4440f13fd2e16204c8fb5932f48da58382f4231e69ea307f866ead44afabe883**。独立校验其 611 个 entry 的路径、字节数和 SHA256，均与当前文件一致；按声明方法重算 canonical digest，也与声明一致。
- 当前 Release 候选：[MacClippyE2E.app](/tmp/macclippy-review-fix-e2e-derived6/Build/Products/Release/MacClippyE2E.app)。[构建日志](/tmp/macclippy-cua-pinboard-final-build.log)含 BUILD SUCCEEDED。
- 先前原生验收候选的 manifest 为 [native final manifest](/tmp/macclippy-cua-native-final-manifest.json)，SHA 为 272ed21dbcfa057c2c43e06b7b12bb595ccf31b7b1802586f56f184cf8ce98d4。与当前版本差异为本轮 Pinboard 的四个生产文件、Xcode 测试注册及新增测试文件。**不能把旧候选 GUI 记录自动改写为新候选的重新验收。**

## 确定问题

没有新增或剩余的确定 P1／P2，因此没有需要附上的新重现步骤或修复建议。以下表格区分源码核实、已执行自动回归和实际 GUI 证据；“未实测”不是判定为缺陷。

## 批准行为逐项核对

| 批准行为 | 当前调用链与结果 | 验证及边界 |
|---|---|---|
| 底部横向卡片、保留现有 Paste 式原生简洁方向 | 卡片／轮播框架沿用现有实现；来源与时间为次级 caption：[ClipboardCardLabel.swift:52](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyClipboardCardLabel.swift:52)、[caption:122](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyClipboardCardLabel.swift:122)。 | 静态核实。未在本代理端进行视觉评分或截图对比。 |
| 单击选择且保留 query；双击复制成功后关闭 | [CardInteraction.swift:19](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockCardInteraction.swift:19)先进入 picker；双击捕获 target，再 copyTarget，只有成功 completion 才 close。 | 自动固定目标回归；build14 GUI 的 Cmd+C／双击有独立 pasteboard 内容及 recipient0 证据。 |
| 搜索第一次 Return 进入当前结果，第二次 Return 才粘贴；无结果不提前粘贴 | [InputPolicy.swift:142](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyDockInputPolicy.swift:142)将 search Return／Tab 映射为 focusResults；[Input.swift:225](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Input.swift:225)检查 marked text 和 currentCount；结果 Return 进入 paste，重复 keyDown 被消费。 | FirstReturn／空结果／原生挂载回归已执行。早期实际 GUI 记录与其 build 分开列在下方。 |
| Tab／Shift-Tab 切换搜索和结果，保留 query、selection | [InputPolicy.swift:150](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyDockInputPolicy.swift:150)、[enterPickerMode:233](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Input.swift:233)没有清 query 或 selection。 | 自动回归；build14 连续真实 Tab／Shift-Tab 保留 query 和选中 arrow02。 |
| 搜索 Space 正常输入；结果 Space 预览开关 | search 模式先返回 native；[InputPolicy.swift:217](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyDockInputPolicy.swift:217)仅结果等表面路由预览；[SearchQueryWritePolicy.swift:196](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyDockSearchQueryWritePolicy.swift:196)跳过编辑时非强制的 normalized whitespace echo。 | 挂载 NSFieldEditor 渐进输入／带 filter 空格回归已执行。build14 实际 Space／Esc 动作通过，但未观察非 key Preview 的全部内容按钮。 |
| IME 的候选确认先交给系统 | router 以 NSTextInputClient marked 状态判断；[AppKitSearchField.swift:129](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyAppKitSearchField.swift:129)的 native command handler 在 marked 状态拒绝提交；未确认的 composing 文本不覆盖 model。 | marked-text 自动回归和最新 final15 连续真实 SCIM 证据已核实；其他输入法与完整 candidate window pixels 仍在证据边界之外。 |
| Cmd+C 复制且不关 Dock | [KeyActions.swift:109](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:109)从显示 Details／Preview target 或当前 focus 复制；没有 hide completion。原生选中文字走 native copy。 | 固定 target 自动回归；build14 实际 Cmd+C 保持面板，未产生 paste recipient 插入。 |
| Esc 分层：popover、editor、多选、搜索先清后关 | modal 和正在编辑 Details 在 router preflight 先处理；查询用 [KeyActions.swift:49](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:49)显式 clear；native popover、Snippet 窗口由各自 responder 处理。创建板提交中 Esc 消费且不关闭。 | 原生 monitor、overlay、dirty／clean editor 和 Pinboard gated 回归已执行；不同层叠的 GUI 组合仍按证据分级。 |
| History／Snippets／boards 是 scope，type／source／date 在搜索旁 | [Navigation.swift:66](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockNavigation.swift:66)呈现 scopes；[filtersButton:133](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockNavigation.swift:133)呈现条件，并在 Snippets 禁用 History 条件。 | 静态核实。build14 实际长名称目标板和 scope 操作已有记录。 |
| 改类型只改对应条件，保留词与原拼写；source／date 同理 | [SearchFilters.swift:109](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockSearchFilters.swift:109)、[applyFields:118](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockSearchFilters.swift:118)均用共同 composing／replacing 策略；日期严格验证，非法值留在表单报错。 | 词、引号、末尾 escape、日期条件自动回归已执行；无重新序列化 bare words 引起的词义变化。 |
| History／boards 保留 query；Snippets 暂存 History 条件，返回恢复 | [Selection.swift:8](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Selection.swift:8)仅进入 Snippets 提取关键词，保留 clauses；退出共同 composing，保护未闭合引号／escape。 | 已执行 Snippets scope／unfinished grammar 回归。 |
| search X 清整个 query；Clear filters 仅清条件 | [HeaderSearch.swift:177](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+HeaderSearch.swift:177)调用 clearSearchQuery，同时清 hidden History clauses；[SearchFilters.swift:54](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockSearchFilters.swift:54)仅保留 keywords。 | 显式 clear、full-query replacement 和投影 commit 自动回归已执行。 |
| picker 直接打字／Backspace 不破坏挂载 filter | [SearchInput.swift:55](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+SearchInput.swift:55)编辑 displayedSearchText，再由 commit 合并条件；不再追加到完整 raw query 的 type:image 末尾。 | route→model→原生 programmatic sync 调用链核实；关键词／纯 filter／引号／escape 回归已执行。 |
| 弹性 header，长板溢出，当前板仍可见 | [HeaderLayoutPolicy:5](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockNavigation.swift:5)按宽度计算；优先当前板；不足时 overflow button 显示当前板名。 | 1024／1280／1440 的预算自动测试；build14 一个真实长名称板。没有完整多长板×宽度×明暗／Reduce Motion GUI 矩阵。 |
| 结果→Preview／Details→返回保留 query、selection、scroll；focusResults 显式转换 | showDetails／showPreview 清搜索意图而不更改底层 query、selection；关闭从当前表面返回 picker；搜索跳转先经 dirty／saving guard。轮播保持同一个 View 状态。 | SurfaceRegression／LateWorkflow／原生 focus 测试已执行；滚动恢复的全面 GUI 矩阵未由本代理实测。 |
| 显式卡片 A 的 Preview／Details 不改后台 B；箭头从显示 A 导航 | [PreviewActions.swift:11](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+PreviewActions.swift:11)仅 active details／preview 从显示 target rebase；picker 仅从当前 focus 移动。 | 真实 routeKeyEvent 的连续箭头测试覆盖 History 和 Snippets、显式 A／后台 B，事件保留强引用；build14 实际连续两次 Right 也前进。 |
| 卡片 hover／focus Copy／More；More 操作固定当前卡片 | [CardQuickActions.swift:9](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyCardQuickActions.swift:9)、[CardMenus.swift:49](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockCardMenus.swift:49)复用同一菜单；copy／paste／preview／edit／delete 捕获 item.id；Transform copy／paste 也固定 ID。 | 静态核实；More 原生鼠标动作已有记录。键盘的主要操作快捷键已验，focused More control 的完整原生键盘可访矩阵未单独观察。批准“转换”按 TextTransform 处理；从卡片转 Snippet 的现有 drag workflow 不扩展为新增菜单要求。 |
| 内容优先，URL domain／path、JSON 限定多行 | [CardLabel+Content.swift:24](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyClipboardCardLabel+Content.swift:24)区分 URL 和 JSON；URL 分 host／path+query，JSON 四行；分类与文本读取有上限。 | 静态核实；完整字体、长文本、内容种类的视觉矩阵未重新做。 |
| Preview Copy／Paste／Edit 使用显示 target | [PreviewActions.swift:36](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+PreviewActions.swift:36)捕获 target；Snippet Edit 执行时按 ID 解析最新 model。 | 固定 ID／旧 preview closure／刷新迟到回归已执行。实际 Preview buttons 的原生逐按钮验证仍有 visual gap。 |
| Details 默认折叠高级信息；编辑仅 Cancel／Save／Save & Paste | [Details.swift:88](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDetails.swift:88)DisclosureGroup；[Details+Sections.swift:104](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDetails+Sections.swift:104)分编辑／只读 footer。 | 静态核实；真实编辑 proof 已有，但版本需按下方列明。 |
| 真 dirty 才 discard；失败保留草稿和 inline error；saving 不允许转换表面 | [Details controller:95](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Details.swift:95)按 editor dirty／saving 判断；[completeDetailsSave:213](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Details.swift:213)仅处理同 request、target、editor，失败复位 saving 并保留 draft。 | Dirty／unchanged／失败／saving 及真实 editor 记录存在。未将文本相同的 Cancel 当成必需确认。 |
| Save & Paste 成功后固定 editedID 粘贴，即使不再匹配 query | [refreshSavedDetails:228](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Details.swift:228)先按 editor.recordID 回读，再 selectRecord(id:)；不使用重新筛选后 focus；目标 PID 由 controller 镜像到 model。 | 固定 ID／query exclusion／保存失败自动回归和实际 editor proof 证据存在；真实外部应用 OSAX delivery 不在隔离 recipient 的证明范围内。 |
| Snippet 名称／正文／trigger／folder 更新、展开配置、关闭与迟到回调 | [Workflow.swift:105](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Workflow.swift:105)、[Lifecycle.swift:234](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Lifecycle.swift:234)保存使用固定 ID；窗口 generation 防止旧 completion 关闭新编辑器；runtime 保存前拿完整 snapshot，成功后更换 expansion snapshot。 | 四字段、duplicate trigger、snapshot failure、旧 session／另一个 preview 回归已执行。final15 真实 create→Edit 四字段→Save→再 Edit，AX 完整显示四个新值，未改 Cancel 无 discard；真实 global event tap 一条测试按配置跳过。 |
| 多选只有一个 cancel；Merge & Paste／Copy／Pin to 显式 | [SelectionHeader.swift:5](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockSelectionHeader.swift:5)有一个 Cancel selection，合并禁用原因，目标板 chooser。 | 自动回归；build14 混合 image＋HTML 原生 range selection、merge disabled、chooser Cancel 与目标板操作已观察。 |
| Cmd+A 异步范围完成前不能冻结可见页子集；失败范围不能部分执行 | [Workflow.swift:5](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Workflow.swift:5)readiness 统一 gate；copy／paste／queue／隐式 delete／pin 都守 readiness；[KeyActions.swift:176](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:176)Return 同样 gate。query 改变使空 pending 范围失效。 | SelectionReadiness 的 pending、full-scope failure、offscreen mixed、completion 全匹配回归已执行，旧 batch tests 也等待真实 selection 完成。 |
| 固定单项操作不被旧全范围失败阻塞 | [Workflow.swift:22](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Workflow.swift:22)显式 IDs 只守非空；requestPinSelection 仅隐式范围守 readiness。 | fixed record pin／pinned delete cancel／fresh Details membership／显式未固定 delete 保留另项回归已执行。 |
| 顺序 paste 与逐表单 queue 区分；Remove 与永久删除区分；数量／板影响确认 | [SelectionHeader.swift:29](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockSelectionHeader.swift:29)明示 displayed order／不移表单；[confirmation:63](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockSelectionHeader.swift:63)明示数量、Pinboard 影响和不可撤销；model 冻结 IDs。 | 自动批量／范围回归；build14 实际 confirmation Cancel 保留两记录与 selection，没有执行永久删除。 |
| New Pinboard 提交态不能取消／重复提交；旧回调不关闭或改新 modal | [Categories.swift:91](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Categories.swift:91)使用当前 modalToken、pending tuple、session；成功才在 model dismiss。View Cancel 与 router Esc 守 submitting。 | 新增四条 gated 回归全部执行通过；final15 原生 storage writer lock 触发创建失败，inline error 和 Name draft 保留，解除后原 draft retry 成功。未捕捉 Creating／disabled Cancel 窗口，也未发送提交中 Esc；此竞态仅由自动回归支持。 |
| 关闭后 copy／manual toast 保留；manual 明示已复制、需 Cmd+V | toast 独立于 Dock；dismiss generation 防止旧任务关新 toast；copy 和 preparedForManualPaste 仅成功 completion 才关闭。 | Manual toast 与 old toast 回归已执行。真实无辅助功能授权的外部应用手动 Cmd+V 尚未由本代理操作。 |
| pause／ignore 状态可见，resume／cancel 有入口 | [Navigation.swift:168](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockNavigation.swift:168)反映 Paused／Skip，菜单恢复／取消。 | build14 实际 pause／resume／ignore／cancel。有一次 stale AX 后操作者追加 Return，记录明确不作为产品重复粘贴证据。 |
| App menu Show History、Help、README／提示一致 | [App.swift:15](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyApp.swift:15)有 Show Clipboard History 和 Help；Help 经 openHelpAfterHide；[Help.swift:49](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyHelp.swift:49)、[README-CN.md:107](/Users/mingjie/Documents/github/personal-projects/mac-clippy/README-CN.md:107)与 router 的两次 Return／Tab／Space／double-click 规则一致。 | 原生 Help 结构自动回归；build14 实际读取和滚动 Help、菜单 Show History 通过。 |

## 前轮确认问题闭环

| 问题组 | 当前修复依据 | 结论 |
|---|---|---|
| picker 打字破坏 type:image；Backspace 删 filter；引号／escape 被重新序列化 | [SearchInput.swift:55](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+SearchInput.swift:55)、[SearchWorkflowPolicy.swift:47](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyCore/MacClippySearchWorkflowPolicy.swift:47)。共同 compose 在词未完成时把条件置前；chip removal 保留词的 lexical spelling。 | 已解决。 |
| full query replacement 被误当成字段投影编辑；Snippets 返回丢条件 | [SearchInput.swift:68](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+SearchInput.swift:68)、[Selection.swift:15](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Selection.swift:15)。 | 已解决。 |
| Space normalized echo 擦掉正在输入的尾部空格；迟到 native focus callback 覆盖实际 responder | [SearchQueryWritePolicy.swift:196](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyKit/Sources/MacClippyPlatform/MacClippyDockSearchQueryWritePolicy.swift:196)、[AppKitSearchField.swift:101](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyAppKitSearchField.swift:101)。 | 已解决，已执行挂载原生回归。 |
| native menu 暂时 blur／Cancel 导致首次 Return 粘贴 | [HeaderSearch.swift:118](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+HeaderSearch.swift:118)忽略仍有明确 search intent 的 blur；显式结果／secondary surface 转换才 reset。 | 已解决。 |
| filter popover 与 modal 分开观察，重叠关闭丢失搜索意图；旧 close 抢新 session 或 preview | [DockView.swift:306](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView.swift:306)统一 presented BOOL；[Modals.swift:8](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+Modals.swift:8)两个 generation／session／reset token；close 在改 mode 前验 opened session。 | 已解决，含两种 blur 时序、filter→menu→Cancel、token 替换、hide／重开回归。 |
| local key monitor 的 nil 经 ?? event 被重新发出 | [Input.swift:36](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Input.swift:36)先 guard self，原样返回 optional route 结果。 | 已解决，已执行 NSApp.postEvent＋安装 monitor＋Details native spy 回归。 |
| dock didResignKey 用旧 pointer 提前关闭内部 Details；异步旧 resign 覆盖重新得到 key 的 Dock | [Input.swift:65](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Input.swift:65)等下一 main turn，再验 monitor generation、真实 key owner、内部 window／menu／popover。Details 为 [nonactivatingPanel:224](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDetails.swift:224)。 | 已解决，已执行 installed-observer／queued-resign 回归；实际 outside click 保留关闭路径。 |
| 显式 A／后台 B 的 preview／Details arrow 从错误 origin 前进；关闭 preview 后 stale target 使 picker 箭头不前进 | [PreviewActions.swift:11](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+PreviewActions.swift:11)按 interactionMode 分流。 | 已解决，含 routed 连续两事件回归。 |
| Details Cmd+F／K 不关闭旧表面；saving 时可以导航；retry 被当成前往 focus | [Input.swift:259](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Input.swift:259)先 guard hideDetails；[PreviewActions.swift:27](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+PreviewActions.swift:27)retry 固定 target。 | 已解决。 |
| Details error／loading Return 可误贴旧记录 | [KeyRouting.swift:68](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyRouting.swift:68)要求加载 ID 匹配；error Return retry，loading／repeat consume。 | 已解决。 |
| Save & Paste 结果变更后使用新 focus；失败丢 draft；旧 callback 替换新 editor | [Details controller:209](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Details.swift:209)验 request／mode／recordID／editor identity；固定 ID 回读粘贴，target PID 镜像至 model。 | 已解决，自动及版本明确的实际编辑证据存在。 |
| Snippet shortcut 误走 clipboard store；旧 Preview Edit 捕获旧 snippet；旧 save 刷新另一 Preview | [KeyActions.swift:87](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:87)、[delete:152](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:152)、[PreviewActions.swift:74](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+PreviewActions.swift:74)、[snippetUpdateHandler:252](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController.swift:252)。 | 已解决。 |
| Snippet commit 后 snapshot 读取失败产生伪保存失败／旧 expansion | [Runtime+Snippets.swift:5](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyRuntime+Snippets.swift:5)在 store lock 内预取 snapshot，成功更新后用非抛错 replacement。 | 已解决。 |
| Cmd+A pending／failed 仍对第一页 copy／paste／queue；空 selection 查询变化留下 pending；fixed ID 也被 readiness 阻塞 | [Workflow.swift:5](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Workflow.swift:5)、[SelectionAll.swift:66](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+SelectionAll.swift:66)。隐式批量守 readiness，显式 ID 独立。 | 已解决。 |
| toast 旧 dismiss 关闭新 toast／关闭 Dock 导致提示消失 | [Feedback.swift:8](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+Feedback.swift:8)独立 toast＋generation。 | 已解决。 |
| Help SwiftUI 文本在原生读取时触发 Sky crash，说明与操作不一致 | [Help.swift:21](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyHelp.swift:21)用 readonly selectable NSTextView／NSScrollView，动态快捷键与实际规则一致。 | 当前版本自动结构与已有实际 GUI 读取／滚动证据支持修复。没有把 Cua 框架崩溃泛化为 VoiceOver 问题。 |
| New Pinboard 提交中 Esc dismiss，旧创建回调 dismiss 同 session 新 modal | [KeyActions.swift:45](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:45)、[Categories.swift:97](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Categories.swift:97)、[Modals.swift:92](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+Modals.swift:92)。 | 已解决，最新候选新增四条回归全部通过。 |

### New Pinboard 最终 delta 的独立核实

入口要求当前 createCategory(modalToken) 且尚未提交，trim 名称后捕获 session。待处理 identity 为 session＋modalToken。回调先验 pending identity，再清自己的 pending；随后验当前 session 与 modal identity，才更新 scope、reload、dismiss 和完成 UI。旧 operation 无法清后来 operation 的 pending；旧 session／换 modal 的存储完成也无法接管新 UI。runtime 已经接受的创建可以完成，但取消／切换后的 UI 不接收旧反馈，这是确定、可解释的语义。

提交期间 router Esc 仍被消费，model dismiss 不执行；View Cancel 同样核当前 token＋submitting。teardown 的明确 dismiss 保留，因此没有为“防取消”阻塞关窗／session 结束。

新 [PinboardCreationWorkflowTests.swift:31](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippyTests/MacClippyPinboardCreationWorkflowTests.swift:31) 的四条测试用 workQueue gate 精确覆盖提交 Esc＋duplicate、同 session modal 替换、旧 completion 对新 pending、关闭重开 session。已有日志确认全部通过。final15 的版本一致原生 [Pinboard proof](/tmp/macclippy-build15-native-review/review-pinboard-proof.json)进一步确认 writer lock 触发失败时 inline error／Name draft 保留，lock process 解除并 rollback／close 后，同 draft 重试创建成功。该次 GUI 演练没有捕捉 Creating＋disabled Cancel 的提交窗口，也没有发送 pending Esc，不能称这条竞态已通过 GUI；其修复结论来自源码守卫及四条 gated 回归。

## 自动验证证据与充分性

| 证据 | 实际日志结果 | 证明范围 |
|---|---|---|
| [最终 App 测试](/tmp/macclippy-cua-pinboard-final-app-tests.log) | XCTest 汇总 500 tests、2 skipped、0 failures；TEST EXECUTE SUCCEEDED；新增四个 Pinboard tests 全部 passed。 | 实际 model/runtime、已挂载 NSHostingView／NSFieldEditor、真实 router／monitor／window notification 的回归。不是全部 GUI 场景的证明。 |
| [最终 Python 测试](/tmp/macclippy-cua-pinboard-final-python-tests.log) | Ran 39 tests，OK。 | 包含已有两个真实隔离 runtime 集成；测试控制查询完整替换及协议约束。不是物理输入／外部 OSAX 测试。 |
| [最终 lint](/tmp/macclippy-pinboard-fix-lint.log) | 535 files；0 violations，0 serious。 | 风格／静态检查。 |
| [最终 Release build](/tmp/macclippy-cua-pinboard-final-build.log) | BUILD SUCCEEDED。 | 当前新候选可构建。 |
| [此前 package 回归](/tmp/macclippy-review-fix-package3.log) | Core 346／1 skipped／0，Platform 400／3 skipped／0。 | 共同 search grammar／composition／input policy；本轮 Pinboard delta 没改这些包。不是最新 App GUI rerun。 |

测试并非只镜像简单实现。主要负例包括：匹配集合跨分页和 offscreen mixed、pending/failed 全范围、query 切换、显式 ID 绕过旧范围失败、两个保留对象的连续 NSEvent、安装 monitor 的真实 NSApp.postEvent、mounted menu blur／modal Cancel 两种时序、异步 opened session close、加载／保存迟到、另一 Preview／新 editor／新操作替换。这些负例直接覆盖前轮真实触发链。

最终 App 两条 skip 的原因可从日志核实：

- Runtime 10k search scale fixture 需要 MACCLIPPY_RUN_SCALE_TESTS=1。
- 真实 session snippet event tap 需要 MACCLIPPY_RUN_REAL_INPUT_TAP_TESTS=1。

未将这些 skip 算作通过；也未为这次可逆 UI 变更额外运行规模／性能测试。

## 实际 GUI 证据与版本边界

实际原生操作由 E2E 代理完成，本代理只读以下证据：

| 记录 | 版本 | 能支持的结论 |
|---|---|---|
| [build14 场景记录](/tmp/macclippy-build14-native-review/review-scenarios.json)、[run 身份](/tmp/macclippy-build14-native-review/run.json) | 272ed21d… | Help 真实读取滚动；应用菜单 Show History；Tab／Shift-Tab query＋selection；Cmd+C keep-open；双击 exact copy close；长名称板创建；mixed selection disable／显式 Pinboard／delete Cancel；pause/resume/ignore Cancel。 |
| [editor proof](/tmp/macclippy-build12-native-review/editor-proof.json)、[run](/tmp/macclippy-build12-native-review/run.json) | 79f5d6e9… | 实际 context Edit、背景 B 与 edited A 不同、clean Escape 无 prompt、dirty Cancel 保留 draft、save failure 留 inline error、Save & Paste 在 query 排除 A 后依然 A 的一次插入。 |
| [IME 最终 recipient](/tmp/macclippy-build13-native-review/ime-continuous-final.json)、[run](/tmp/macclippy-build13-native-review/run.json) | 3c61cddf… | 实际 SCIM composition／candidate 确认记录，确认后／firstReturn recipient0、后续 recipient1。中间 focus snapshot 曾出现 Dock visible=false，不能单凭该 snapshot 宣称完整连续 focus 链都已通过。 |
| [初始验收索引](/tmp/macclippy-cua-native-acceptance.json) | 顶层 272ed21d…，包含不同历史构建的 editor／IME 子记录 | 作为证据索引使用；不把顶层 SHA 套到所有历史 proof。 |
| [final15 editor proof](/tmp/macclippy-build15-native-review/review-editor-proof.json)、[run 身份](/tmp/macclippy-build15-native-review/run.json) | 当前源码 4440f13f… | 真实 context Edit A／背景选中 B；unedited Esc 仅退出编辑；dirty Keep Editing 保留 draft；保存失败 inline error＋draft；移除失败 fixture 后 Save & Paste，query 只剩 B，recipient 一次插入且 SHA 与 edited A 相同。 |
| [final15 IME proof](/tmp/macclippy-build15-native-review/review-ime-proof.json) | 当前源码 4440f13f… | 当前系统 Pinyin 输入源未改变，真实逐 key composing、Space 确认中文；确认／firstReturn／secondReturn recipient 分别为 0／0／1，SHA 与目标相同。系统 candidate 窗口完整 pixels 没暴露在 Dock 裁剪截图。 |
| [final15 Snippet proof](/tmp/macclippy-build15-native-review/review-snippet-proof.json) | 当前源码 4440f13f… | 真实 More NewSnippet→卡片 More Edit→改四字段→Save→再 Edit，观察 name／trigger／folder／body 全部新值；未修改 Cancel 无 discard。未验证外部 global trigger expansion。 |
| [final15 Pinboard proof](/tmp/macclippy-build15-native-review/review-pinboard-proof.json) | 当前源码 4440f13f… | 真实 writer lock 已 acquire，硬期限解除并 rollback／close；创建失败 inline error＋draft 保留，同 draft retry 正常成功。pending Creating／disabled Cancel 窗口未观察、pending Esc 未发出，GUI 不证明该竞态。 |

build14 的限制也已保留：Preview 为 non-key panel，动作链 Space／Esc／两次 arrow 被观察，但其全内容／buttons 视觉没有被 Cua 读到；Snippet 四字段修改保存与 card refresh 被观察，isolated SQLite 明文只能核 trigger_value 与加密 envelope，完整四字段重新打开的连续证明当时中断。一次 modifier click 未证明 modifier 到达，一次 Snippet menu 中断伴随 foreground 变化；均没有足够证据定为产品 bug，不能升级为确定 P2。

## 实际尚未覆盖的边界

1. 最新 4440 候选的真实编辑、IME、Snippet 四字段保存后重新打开、Pinboard 创建失败留 draft／retry 均已有版本一致 proof。New Pinboard 的 Creating＋disabled Cancel 提交窗口未被 GUI 捕捉，pending Esc 未发出；这条竞态由已通过的 gated controller／window／storage 回归证明，不能称 GUI 验收通过。历史 proof 只作为补充，不替代新版记录。
2. 真正外部应用的 Accessibility／CGEvent 注入与目标应用切换：隔离 E2E 使用 run-local pasteboard 和 synthetic recipient 镜像，不证明任意外部应用 OSAX delivery。固定 record／PID、manual fallback 的源码与自动测试已核实。
3. 真实 global Snippet expansion event tap 的权限、输入与前台 app 环境；当前 App 有一条明确跳过。四字段持久化／snapshot 更新已有自动回归。
4. 1024／1280／1440、多且长的板名称、light/dark、Reduce Motion 的全组合视觉矩阵。现有预算测试、dynamic labelColor／Reduce Motion 源码、一个真实长板例子能支持部分行为，不能声称完整 GUI 组合已验收。
5. 多屏／full-screen Spaces、不同 IME 与 candidate window；现有策略与 SCIM 证据不证明所有系统环境。
6. Preview non-key 内容按钮的完整原生鼠标／键盘逐项链；最主要固定 ID 与 late callback 逻辑已有自动回归。
7. 大数据 scale fixture 本轮未执行；本报告不对吞吐／长期运行性能做新增结论。

这些是验收范围的边界，没有被当作确定缺陷或未经授权的扩展工作。当前审查没有发现需要继续修改源码的确定 P1／P2。

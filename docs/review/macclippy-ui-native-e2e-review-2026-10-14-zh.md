# MacClippy 原生 GUI E2E 独立复审

复审完成。**当前剩余确认的 P1/P2 为 0。** 本轮发现的提交中 New Pinboard Esc / 迟到回调问题已修复并有四条 gated 回归；正常创建、失败保留草稿和重试已原生复验。提交中 Esc 的短窗口未被工具捕捉，不能称该 race 已由 GUI 实测通过。

最终候选 build15 SHA：`4440f13fd2e16204c8fb5932f48da58382f4231e69ea307f866ead44afabe883`。独立完整矩阵先在 build14 `272ed21dbcfa057c2c43e06b7b12bb595ccf31b7b1802586f56f184cf8ce98d4` 运行；Pinboard 修复后在 build15 重跑相关关键路径、中文 IME、Snippet 和 Help。下表区分实际构建，不把过去 build12/13 场景归给最终构建。

GUI 全部通过文档内 Cua API 操作。authenticated E2E 控制仅用于夹具、身份、指标和接收计数；没有用控制方法冒充点击。每个场景均使用隔离 named pasteboard / recipient。native host 只是接收内容的可见镜像，不等于外部 TextEdit/Safari 等应用，也不证明真实 OSAX、全局快捷键或全局触发词展开。VoiceOver 按用户明确要求排除。未操作生产 MacClippy PID788、真实历史、general clipboard、Keychain、输入源或系统偏好。

## 原生实际覆盖

| 场景 | 构建 | 实际观察与结论 | 证据 |
|---|---|---|---|
| 英文筛选→菜单→取消→两次 Return | 15 | 原生输入关键词→Text filter→点搜索框关闭popover，三项 searchMode/intent/firstResponder 均true。真More菜单tracking中合成capture触发repaint仍可操作；NewPinboard Name获focus；Cancel后关键词、筛选、记录和search focus保留。首Return Dock开、recipient0、named board保持capture的53bytes；次Return Dock关、recipient1且SHA匹配选中记录。**通过** | [关键链证明](/tmp/macclippy-build15-native-review/review-filter-menu-proof.json) |
| 中文组合输入/确认/两次 Return | 15 | 逐个真实按键 zhongwen→截图有下划线的“zhong wen”，组合输入阶段8条结果未提前变化。Space由现有Pinyin输入源确认“中文”，查询收敛1条。确认、首Return、次Return计数0/0/1，最终payload正确。**通过**；候选窗口像素没有被Dock截图暴露 | [IME证明](/tmp/macclippy-build15-native-review/review-ime-proof.json) |
| 编辑固定ID、未改/dirty cancel、保存失败、Save & Paste | 15 | 查询workflowneedle选B，真实右键A→Edit绑定A。未改Esc只取消编辑、Details仍开；dirtyCancel有提示，Keep Editing保留草稿。仅在认证fixture装SQL故障trigger，Save显示inline error、保留draft、recipient0。移除trigger后Save&Paste插入A的新内容1次；A已不匹配查询，剩余结果只有B。**通过** | [编辑证明](/tmp/macclippy-build15-native-review/review-editor-proof.json) |
| Snippet四字段保存与重新打开 | 15 | 真More→NewSnippet创建；card More→Edit修改名称、正文、trigger、folder，Save后再次真实Edit完整看到FinalSnippetNew/;f15new/Final/New/new body。card与隔离数据库trigger同步更新。未改Cancel不提示丢弃。**通过**；外部全局展开未测 | [Snippet证明](/tmp/macclippy-build15-native-review/review-snippet-proof.json) |
| New Pinboard故障/重试/创建 | 15 | 临时writer lock仅锁认证fixture DB，最终AX已显示创建失败并保留Name；没有捕捉到Creating+disabled Cancel，因此没有发pending Esc。锁30秒硬超时ROLLBACK并关闭，retry同draft成功、选中空board。**失败保留与重试通过；pending Esc未原生实测** | [Pinboard证明](/tmp/macclippy-build15-native-review/review-pinboard-proof.json) |
| Help真实菜单/可读性/滚动 | 15 | 真Help菜单打开native文档，截图排版可读，实际约定一致；滚动条0→0.9512，底部筛选与设置指导可读，关闭返回host。**通过** | Cua实际AX/截图；[清理前记录](/tmp/macclippy-build15-native-review/review-cleanup-before-stop.json) |
| Tab/Shift-Tab与非首项选择 | 14 | build14arrow→Tab→Right选02→ShiftTab回search→Tab回results，查询/02选择保留。**通过** | [build14场景记录](/tmp/macclippy-build14-native-review/review-scenarios.json) |
| Space/Preview往返→两次Right | 14 | Space→Esc保持Dock/查询/选择；03经Preview关闭后Right→02，再Right→01。**键盘后果通过**；非key Preview完整内容/按钮像素未被Cua暴露 | 同上 |
| 单击/⌘C/双击 | 14 | 单击选择保留结果。结果⌘C保留Dock，named board准确为01、recipient0；双击02关闭Dock，named board准确为02、recipient0。**通过** | [⌘C板证明](/tmp/macclippy-build14-native-review/review-cmdc-board.json)、[双击板证明](/tmp/macclippy-build14-native-review/review-doubleclick-board.json) |
| 混合多选/明确固定目标/删除取消 | 14 | ShiftRight真实选Image+HTML两项，Merge Copy/Paste禁用并说明仅兼容文字可合并；Pin chooser Cancel保留选择，再指定长名board后该board含两项。More区分顺序粘贴/移出board/删除history；删除确认明确2项与Pinboards影响，Cancel后两项/选择保留。**通过，未永久删除** | [build14场景记录](/tmp/macclippy-build14-native-review/review-scenarios.json) |
| 暂停与待忽略复制 | 14 | Until I resume显示Paused，Resume恢复正常More；Ignore显示Skip1，Cancel后menuTracking=false且freshAX恢复More。**通过** | [menu tracking诊断](/tmp/macclippy-build14-native-review/review-ignore-cancel-metrics.json) |

## 已修复问题与自动佐证

New Pinboard提交中Esc原先可dismiss，旧creation completion也可能关闭新modal。当前 [键盘guard](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockController+KeyActions.swift:46)、[创建上下文/session/token guard](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockModel+Categories.swift:97)、[modal Cancel guard](/Users/mingjie/Documents/github/personal-projects/mac-clippy/MacClippy/MacClippyDockView+Modals.swift:98) 已闭环。四条gated/controller+真实window/storage回归是异步race证据；不称SwiftUI editor mounted或真实GUI pending Esc覆盖。

最终App检查500 executed、2 skipped、0 failures：[日志](/tmp/macclippy-cua-pinboard-final-app-tests.log)。Python39 tests全部通过、3.864秒：[日志](/tmp/macclippy-cua-pinboard-final-python-tests.log)。SwiftLint535 files、0 violations：[日志](/tmp/macclippy-pinboard-fix-lint.log)。本代理没有与root同时运行windowed test host。

[14→15 manifest差异](/tmp/macclippy-build15-native-review/review-delta.json) 明确列出Pinboard相关model/modal/keyboard代码、project引用及新增测试变化。build14其他场景没有宣称全部在最终构建重复。

## 工具瞬态与未实测边界

一次新fixture绑定“native pipe closed”经文档化reset→inventory→认证exact path恢复；没有证据证明App crash。Edit Content一次AXError.failure、Snippet重新打开一次0×0 capture，以及取消一次AXError.failure，都先读取freshAX确认动作已成功，未重试导致重复操作。

部分菜单click已完成，但即刻AX仍显示旧selected菜单。build14 Resume后错误追加一次Return，导致所选HTML粘贴到隔离recipient；它是测试附加按键，不是产品重复粘贴。之后使用menuTracking诊断及freshAX，最终15关键链没有额外菜单Return。

build14一次Snippet More操作受前台切换打断；root focus日志显示active=false→outside-pointer-hide。build15用连续freshAX guard再次More/Edit/reopen成功。Cua numeric/coordinate Command-click只观察到单选，未证明modifier实际抵达；混合多选通过ShiftRight完成，不据此认定产品P2。

仍未直接原生验收：pending提交Esc的瞬时窗口、完整非key Preview与关闭后HUD像素、外部收件App/OSAX/全局触发词展开、物理1024/1280/1440屏幕及完整明暗/降低动态效果组合。1024/1280/1440 long-board主题图来自原生NSHostingView自动布局测试，searchfield实际宽>=200；它们是透明host缓存，不能冒充完整Dock/物理屏幕验收。按root指示不扩系统设置场景。

## 安全退出

build14 PID35009、最终15 PID62306均authenticated terminate并等待退出；writer-lock PID68843也已退出并ROLLBACK/close。两owned roots均lockfalse：[独立退出证明](/tmp/macclippy-cua-e2e-shutdown-proof.json)。最终fixture故障trigger为空：[清理前证明](/tmp/macclippy-build15-native-review/review-cleanup-before-stop.json)。root另外核查本轮9个owned roots全部lockfalse、生产PID788仍在：[汇总清理](/tmp/macclippy-cua-final-cleanup-proof.json)。

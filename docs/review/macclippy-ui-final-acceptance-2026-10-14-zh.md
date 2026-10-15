# MacClippy UI 与操作流程：最终复审及原生验收

2026-10-14。本轮确认的 P1/P2 已修复。工程、操作流程和原生 GUI E2E 三名独立子代理完成终审，未发现剩余确认的 P1/P2。VoiceOver 按用户最新要求排除。

最终 Release E2E 构建与当前 611 个 build inputs 一致，source SHA：`4440f13fd2e16204c8fb5932f48da58382f4231e69ea307f866ead44afabe883`。真实 GUI 使用隔离数据、运行内命名剪贴板和原生接收窗口。

## 本轮关键修复

- Dock 失去 key 后等待 AppKit 完成交接，识别 Details、Preview、菜单、弹层和重新获得 key 的窗口，避免 AX 操作时静止在窗口外的指针误关面板；实际外部点击仍正常关闭。
- Details 使用可获得 key 的 nonactivating panel，编辑窗口能稳定接管焦点。
- Help 改为原生可选择、可滚动的文本视图，避免旧 SwiftUI AX 树触发 Cua 原生服务崩溃；菜单、帮助和 README 维持同一操作约定。
- E2E 增加按需打开的原生接收窗口，Dock 关闭后仍可读取目标；重开面板的 readiness 检查使用实际可见、可交互的窗口状态，避免依赖再次触发 onAppear。
- 修复复审确认的固定板 P2：提交时 Esc 不绕过禁用的取消按钮，完成回调同时验证 session、打开时的 modal token 和当前操作身份，旧回调不能关闭新对话框或改变新范围。

此前确认的搜索、全范围多选、固定 ID 编辑粘贴、Snippet 更新、消费按键和迟到弹层/提示回调问题也已逐项复核，详见独立报告。

## 自动验证

| 验证 | 最终结果 |
| --- | --- |
| App 全量回归 | 500 执行，498 通过，2 个 opt-in 跳过，0 失败 |
| 新固定板竞态回归 | 4 条全部通过：提交 Esc/重复提交、替换对话框、旧完成不能清新提交、关闭再打开会话 |
| E2E 驱动 Python | 39 条全通过，包含 full-query 与 native-host 两条真实运行时集成 |
| SwiftLint | 535 个文件，0 违规 |
| Release / source identity | 构建成功，Info.plist、manifest、当前源码 SHA 一致 |

日志：[App](/tmp/macclippy-cua-pinboard-final-app-tests.log)、[Python](/tmp/macclippy-cua-pinboard-final-python-tests.log)、[lint](/tmp/macclippy-pinboard-fix-lint.log)、[Release](/tmp/macclippy-cua-pinboard-final-build.log)。

## 真实原生 GUI 验收

最终 build15（SHA `4440f13f…`）重新实测以下关键路径：

| 场景 | 实测结果与证据 |
| --- | --- |
| 类型筛选 → 真实菜单 → 新建固定板取消 → 两次 Return | 查询、筛选、选择与搜索焦点保留；第一次不粘贴，第二次仅插入一次。[证据](/tmp/macclippy-build15-native-review/review-filter-menu-proof.json) |
| 背景选中 B、右键编辑 A | 未修改退出不询问丢弃；dirty Cancel/Keep Editing 保留草稿；保存失败保留草稿与内联错误；保存成功后即使 A 不再匹配查询，仍只粘贴 A。[证据](/tmp/macclippy-build15-native-review/review-editor-proof.json) |
| 真实中文 Pinyin IME | 逐键组合期间不提前过滤；Space 确认中文；确认后/首 Return/次 Return 的接收次数为 0/0/1，内容 hash 与目标一致。[证据](/tmp/macclippy-build15-native-review/review-ime-proof.json) |
| Snippet 编辑 | 名称、正文、触发词、目录保存后再实际打开 Edit，四字段均为新值；未改 Cancel 无丢弃提示。[证据](/tmp/macclippy-build15-native-review/review-snippet-proof.json) |
| 固定板创建故障及重试 | 隔离存储故障后名称与内联错误保留；解除故障后同草稿重试成功。[证据](/tmp/macclippy-build15-native-review/review-pinboard-proof.json) |
| 原生 Help | 真 Help 菜单打开，内容可读，滚动到底，Cua 服务未再崩溃。[证据](/tmp/macclippy-build15-native-review/review-cleanup-before-stop.json) |

build14（SHA `272ed21d…`）另有真实导航、复制与整理矩阵：Tab/Shift-Tab 保留查询和非首项选择；Space/Esc 后箭头从当前焦点继续；⌘C 保持打开；双击复制后关闭；混合多选禁用不兼容合并并说明原因；指定固定板与取消；批量删除确认数量和固定板影响、取消保留记录；暂停/恢复与忽略/取消。[逐场景记录](/tmp/macclippy-build14-native-review/review-scenarios.json)。这些记录单独标注版本，没有冒充 build15 重复验收。

固定板提交中的短暂 Creating/disabled Cancel 状态没有被 GUI 捕捉，因此没有发送或宣称验证该状态下的 Esc；这一竞态由四条确定性的 controller/窗口/真实存储回归及两名独立源码复审支持。

1024/1280/1440、多长名称固定板及明暗布局有原生 NSHostingView 渲染与实际搜索宽度断言；Reduce Motion 有自动策略覆盖。未宣称所有物理屏幕/主题/动态设置组合、non-key Preview/HUD 全部像素、外部应用粘贴投递或全局 Snippet event tap 均经过本轮 GUI 实测。隔离原生接收窗口验证粘贴次数和内容。

## 工具恢复与清理

菜单动作或窗口切换后先刷新 AX，确认当前状态再继续，避免重复执行已成功的动作。测试 App 重启后的一次 native-pipe 断连通过 Cua reset、重新读取 inventory、绑定已验证的精确 E2E app 路径恢复；操作步骤已写入 [E2E 指南](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/e2e-phase5.md)。

9 个本轮 owned roots 均已释放锁，运行内故障 trigger 已移除，临时 SQLite writer lock 已回滚并退出；生产 MacClippy PID 788 仍运行。[清理证明](/tmp/macclippy-cua-final-cleanup-proof.json)。

## 独立完整报告

- [工程复审](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/macclippy-ui-engineering-review-2026-10-14-zh.md)
- [操作流程复审](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/macclippy-ui-workflow-review-2026-10-14-zh.md)
- [原生 GUI E2E 复审](/Users/mingjie/Documents/github/personal-projects/mac-clippy/docs/review/macclippy-ui-native-e2e-review-2026-10-14-zh.md)

[版本化验收汇总](/tmp/macclippy-cua-native-acceptance.json) 保留每个场景的构建 SHA、测试日志与实测边界。

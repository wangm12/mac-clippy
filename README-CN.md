<p align="center">
  <a href="README.md">English</a> · <a href="README-CN.md">中文文档</a>
</p>

<p align="center">
  <img src="MacClippy/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="MacClippy 图标" width="128" height="128" />
</p>

<h1 align="center">MacClippy</h1>

<p align="center">
  <strong>专为 macOS 打造的原生剪贴板管理器。</strong><br>
  使用 Swift、AppKit、SQLite FTS5 搜索、本地 Vision OCR 与剪贴板内容加密。
</p>

<p align="center">
  <a href="https://github.com/wangm12/mac-clippy/releases/tag/nightly"><img src="https://img.shields.io/badge/每日构建-nightly-blue.svg?style=flat-square" alt="Nightly Build" /></a>
  <a href="https://github.com/wangm12/mac-clippy/releases"><img src="https://img.shields.io/github/v/release/wangm12/mac-clippy?style=flat-square" alt="GitHub Release" /></a>
  <img src="https://img.shields.io/badge/平台-macOS%2014%2B-lightgrey?style=flat-square" alt="平台" />
  <img src="https://img.shields.io/badge/架构-Apple%20Silicon%20%7C%20Intel-orange?style=flat-square" alt="架构" />
  <img src="https://img.shields.io/badge/开发语言-Swift%206-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift" />
</p>

---

## 产品简介

macOS 剪贴板保存当前内容。复制新内容后，之前的内容会被替换。

**MacClippy** 是一款 macOS 原生剪贴板管理器，可采集受支持的剪贴板表示形式，在本机保存可搜索的历史记录，并提供固定板、快捷片段和粘贴工具。

MacClippy 将剪贴板观察和存储设计为本地操作。实际响应速度和资源占用会随 Mac、macOS 版本和历史数据而变化；本文不提供与其他产品的性能对比数据。

---

快速导航：[功能与使用](#功能与使用指南) · [性能与容量](#性能与容量) · [快捷键](#常用快捷键一览) · [安装](#下载与安装指南) · [开发](#开发与测试常用命令) · [隐私](#隐私与数据安全说明)

## 功能与使用指南

以下说明对应当前仓库实现。界面中的 **History / All** 是历史记录入口，**Pinboards** 是固定板，**Snippets** 是快捷片段。

### 快速上手

1. 启动 MacClippy，在任意应用中复制一段文字或一张图片。
2. 按 `⌘⇧V` 或点击菜单栏图标打开历史面板；打开快捷键可在设置中修改。
3. 输入关键词查找，按 `Return` 从搜索框进入结果，用方向键选择，再按 `Return` 粘贴到之前的工作窗口。
4. 只想复制时，双击卡片会复制并关闭面板；`⌘C` 或右键 **Copy** 会复制并保留面板。
5. 通过齿轮打开设置；**More actions → Shortcuts & Search Help…** 可查看应用内帮助。

### 历史采集与卡片

- 保存受支持的纯文本、RTF、HTML、图片及文件／文件夹引用；可保留同一次复制中的多项内容和多种剪贴板表示形式。
- 卡片按内容展示文本预览、图片缩略图、文件信息、链接或十六进制颜色预览，并显示可用的来源应用信息。
- 文件记录保存的是引用，不会把原文件完整归档；原文件移动或删除后，引用可能失效。
- 超出采集限制或暂时无法读取的表示形式可能被标记为不可用，不能保证所有应用的私有格式都能完整重放。详情页可查看实际保留的格式与状态。
- 历史按需分页加载；URL 和 Image 是内置快捷筛选，右键删除这类筛选只隐藏入口，不删除历史内容。
- 原生悬浮面板支持多显示器和全屏空间，并适配系统深浅色、减少动态效果、降低透明度及高对比度设置。

### Copy、Paste、重复复制与排序

普通 History 按记录的 **修改时间 `modified` 降序** 排列；时间相同时依次按 Lamport 值、记录 ID 降序排列。它不是按最近一次使用时间排序。

| 操作 | 剪贴板／目标应用行为 | 历史排序与计数 |
|---|---|---|
| 单击卡片 | 选择该项 | 不移动，不增加使用次数 |
| 双击卡片 | 复制到系统剪贴板，成功后关闭面板 | 不移动，不增加使用次数 |
| `⌘C`／右键 Copy | 复制到系统剪贴板，保留面板 | 不移动，不增加使用次数 |
| Copy plain／Copy transformed | 复制本次派生的纯文本 | 不改原记录，不移动，不增加使用次数 |
| 在结果中按 `Return`／选择 Paste | 向目标应用发送粘贴操作 | 成功发送后使用次数 +1、更新最近访问时间；不移动 |
| 在其他应用重新复制相同内容 | 监听器采集并尝试去重 | 命中后复用旧记录，使用次数 +1，更新访问时间和修改时间，排到最新位置 |
| 编辑内容或重命名历史项 | 保存对原记录的修改 | 更新修改时间，可能改变其在 History 中的位置 |

例如当前从新到旧为 **C → B → A**：在 History 双击、Copy 或直接 Paste B 后，仍为 **C → B → A**；在其他应用重新复制 B 且去重命中后，变为 **B → C → A**。

去重根据主内容及各剪贴板表示形式计算哈希，并验证已有记录；不是只比较卡片上显示的文字。相同文字携带不同的 HTML、RTF 或其他格式数据时，可能形成不同记录。命中后保留旧记录 ID、原始创建时间、来源信息、自定义名称和固定板关联，不插入第二条。

应用自身的常规 Copy／Paste 会被监听器识别并跳过，避免再次收录。**预览中复制选中文字或 OCR 文字是例外**：提取出的文本会作为一次用户复制参与历史采集，仍受暂停、排除规则和去重约束。

使用次数是辅助元数据：它既可能因成功发送粘贴而增加，也可能因外部重复复制而增加，不等于目标应用实际接受内容的次数。复制后在其他应用手动按 `⌘V` 不会单独增加此计数。

### 原格式、纯文本与批量粘贴

- 默认 `Return` 使用保留的格式，`Shift-Return` 使用纯文本；打开 **Always paste as plain text** 后两者对调。纯文本转换适用于文本兼容内容。
- 按住 `⌘` 点击可切换多个选中项，`Shift` 点击可扩展范围；在 History／固定板结果中用 `⌘A` 选择当前查询的全部匹配项，包括尚未显示的分页结果。
- **Merge & Copy / Merge & Paste**：将文本兼容项按显示顺序转换为纯文本，以换行连接。复制只写入剪贴板；粘贴发送一次合并内容，并为各原记录更新使用次数。含图片、文件或不可读文本时不能合并，不会悄悄丢弃部分选项。
- **多选工具栏 → More → Paste selected items sequentially**：依次发送各项到同一个目标应用，支持逐项处理不同类型。不会自动按 Tab 切换字段，也没有“粘贴下一项”快捷键；不可用项、失败及中断会通过结果反馈。
- 自动粘贴需要辅助功能权限。无权限或发送失败时请根据面板提示处理，也可以用 Copy 后手动粘贴。发送成功表示已提交系统粘贴事件，不保证每个目标应用都已消费剪贴板内容。

### 搜索与筛选

使用 SQLite FTS5 全文索引，支持中文、日文、韩文连续字串检索、英文前缀及带引号的词组查询。可搜索内容预览、已识别的 OCR 文字、自定义名称等已索引信息。

| 查询 | 含义 |
|---|---|
| `设计稿`、`git commit` | 关键词检索 |
| `"meeting notes"` | 带引号的词组查询 |
| `clip*` | 前缀匹配 |
| `type:text`、`type:rtf`、`type:html` | 按实际存储的文本类型筛选；`type:text` 不包含后两者 |
| `type:image`、`type:files`、`type:url` | 图片、文件引用或网址 |
| `app:Xcode`、`app:微信` | 来源应用名称或 Bundle ID 的匹配 |
| `name:欢迎语` | 自定义名称匹配；`label:`、`tag:` 是同义写法，不是独立标签系统 |
| `has:name`、`has:label` | 具有非空自定义名称 |
| `has:ocr` | 具有已识别的 OCR 文字 |
| `after:2026-01-01` | 修改时间在该日本地零点及之后，包含当天 |
| `before:2026-02-01` | 修改时间严格早于该日本地零点，不包含当天 |
| `报错 type:text app:Terminal` | 组合关键词和结构化条件 |

搜索旁的筛选按钮提供类型、来源应用和日期条件；日期依据修改时间，不是原始创建时间。修改筛选、选择卡片、预览和编辑会保留查询。切到 Snippets 暂时只使用关键词，返回 History 恢复历史筛选。搜索框的 × 清除关键词与筛选；**Clear filters** 只清除条件。

### 预览、OCR、详情与编辑

- 在结果中按 `Space` 打开或关闭预览，查看完整文本、富文本、图片等受支持内容；搜索框中的空格仍正常输入。
- Apple Vision 在本机识别图片文字，识别结果可参与搜索；图片预览提供识别文字选择与复制。识别效果取决于图片质量和语言，未识别出文字的图片不会匹配 `has:ocr`。
- `⌘⌥V` 或右键 **Details…** 查看来源、创建／修改／访问时间、使用次数、自定义名称、固定板归属、OCR、图片尺寸、文件路径，以及保留的格式、大小和可用状态。
- 通过 **Rename…** 为记录命名。文本兼容项支持 **Edit…**；详情中 `⌘E` 编辑，`⌘S` 保存，`⌘Return` 保存并粘贴。编辑会修改已存内容并更新搜索索引；图片和文件不提供文本内容编辑。
- 卡片可拖入固定板；拖到 Snippets 可从文本兼容项建立片段。也可把支持的文本、RTF、HTML、图片或文件引用拖到接受相应格式的其他应用。

### 固定板与删除

- 使用 **+ / New Pinboard…** 创建固定板，右键可重命名、换颜色或删除固定板。
- 卡片菜单 **Pin to list**、`⌘P`、多选工具栏 **Pin to…** 或拖放可添加关联；同一历史项可以加入多个固定板。
- 固定板引用原历史项，不另存一份内容。被任何固定板引用的项目受保护，不参与日常自动清理、旧图片压缩及设置中的“删除未固定历史”。
- **Remove from this Pinboard / Remove from list** 只解除关联；删除固定板只删除分类，历史项仍在。失去最后一个固定板关联后，该项重新受普通保留策略约束。
- **Delete from history… / Delete permanently** 删除原记录，并从所有固定板移除；批量删除或涉及固定项时会要求确认。设置中的 **Delete unpinned history** 保留固定项。

### 快捷片段（Snippets）

通过 **More actions → New Snippet…** 新建，或将文本兼容卡片拖入 Snippets。片段有名称、正文、可选触发词和文件夹标签（例如 `工作/邮件`）；可右键编辑、预览、复制、粘贴或删除。名称和正文不能为空，触发词不能重复。

- **Expand with Space**：逐字输入英文分号开头的 `;trigger`，再按空格展开。
- **Confirm with Tab**：输入同样的触发词，改按 Tab 确认。
- **Off**：关闭键入展开，仍可从面板复制／粘贴片段。
- 复制粘贴整串触发词不会触发展开；Return 不触发展开。全局键入展开需要辅助功能和输入监控权限。
- 正文中的 `{{date}}`（`YYYY-MM-DD`）、`{{time}}`（`HH:mm`）和 `{{clipboard}}`（当前剪贴板文字）在使用时替换；日期与时间使用本地日历。未知变量保留原文，不执行脚本。

### 文本变换（Transform）

在文本兼容卡片的右键菜单或详情的 **More → Transform** 中选择操作，再选 **Copy transformed** 或 **Paste transformed**。当前提供以下八项：

| 变换 | 行为 |
|---|---|
| Uppercase / Lowercase / Title Case | 大写、小写、按空白分词的词首大写 |
| Trim whitespace | 去除首尾空白和换行 |
| Pretty JSON | 格式化有效 JSON 并排序键；无效输入保留原文 |
| Clean tracking URL | 移除受支持的 URL 跟踪参数 |
| Markdown quote | 为每行添加 `> ` 引用前缀 |
| Sort lines | 按本地自然比较顺序排列各行 |

变换将 HTML／RTF 转为纯文本后操作，只影响本次复制或粘贴；不覆盖原记录或其搜索索引。图片和文件不支持文本变换。

### 暂停采集与隐私规则

- **More actions → Pause capture** 或设置的 **Pause capture**：暂停 30 秒、5 分钟、1 小时，或直到手动恢复；定时暂停到期自动恢复。
- **Ignore next copy / Skip next copy** 或 `⇧⌥⌘C`：跳过下一次剪贴板变化；重复操作可累计待跳过次数，也可在 More actions 中取消。它不会删除已有记录。
- 默认排除内置密码管理器应用、隐藏及临时剪贴板类型；可在设置中添加排除应用和逐行正则文本规则。
- **Capture All** 可包含隐藏和临时内容，内置密码管理器排除仍然生效；暂停和自定义排除规则仍然适用。
- 暂停／排除只影响后续采集，不会清除已经保存的历史。载荷加密与明文搜索元数据的边界见下文“隐私与数据安全说明”。

### 设置、维护与恢复

| 设置或工具 | 用途 |
|---|---|
| General：Shortcut、App visibility、Launch at login | 自定义打开快捷键、分别隐藏菜单栏／Dock 图标、开机启动；两个图标都隐藏时通过快捷键打开 |
| History：Day / Week / Month / Unlimited | 按修改时间选择 1／7／30 天或不限时保留；固定项受保护 |
| History 容量面板 | 查看条目及载荷预算使用情况；“不限时”仍受数量和容量约束 |
| Compress old images | 手动压缩修改时间超过 7 天的未固定图片，目标最长边不超过 2048 像素，仅提交有收益的压缩；会改变保存的图片 |
| Storage → Health / Refresh | 查看、刷新存储健康状态 |
| Storage → Repair search index | 从已存数据重建搜索索引，不是数据库损坏修复工具 |
| Export diagnostics | 导出健康计数和已脱敏事件，用于排查问题；不导出历史正文 |
| Create backup | 将本机历史、固定板、片段及图片／附件数据保存为备份 |
| Restore backup | 校验后用备份替换本机历史、固定板和片段；不是合并导入，需要原安装的加密密钥 |
| Delete unpinned history | 手动删除未固定历史，保留固定项 |

备份不导出钥匙串密钥，也不提供跨设备迁移。权限页可打开辅助功能和输入监控设置，并查看当前运行的应用路径；更换应用副本或系统权限状态未刷新时，可在授权后退出并重新打开应用。

---

## 性能与容量

MacClippy 使用原生 Swift/AppKit 组件和 SQLite FTS5 索引。仓库包含回归和规模测试夹具，但这不等于已发布延迟、内存、CPU 或跨产品基准数据。本文没有发布数值性能目标或实测结果，也不提供启动时间、RSS、搜索延迟或动画帧率对比。

剪贴板观察在活跃使用期间以及检测到剪贴板变化后的短暂窗口内，约每 50 毫秒轮询一次。若约 30 秒没有用户输入或近期剪贴板变化，间隔会调整为约 400 毫秒。系统睡眠时会暂停轮询。

历史记录同时受保留时间、条目数量和载荷容量限制：

- 默认未固定历史条目上限为 **10,000** 条；固定项不计入这个条目上限。
- 保留图片载荷的清理预算为 **2 GiB**；这不是单张图片上限。统计包含固定图片，但清理只删除未固定图片，固定图片可能使实际占用超过预算。
- 未固定历史的合计载荷清理预算为 **4 GiB**；固定项受保护。
- 容量面板是使用情况概览，不是严格磁盘配额；数量与载荷预算当前不提供设置编辑器。
- **不限时**只表示不按年龄自动过期，条目数和载荷容量限制仍然生效。SQLite 元数据、索引、日志和文件系统开销不计入这些载荷预算，因此它们不是整个应用支持目录的严格磁盘空间上限。

参见[基于一手来源的竞品行为比较与工程建议](docs/competitive-comparison.md)。

---

## 常用快捷键一览

| 快捷键 | 功能说明 |
|---|---|
| **`⌘ ⇧ V`** | 唤出或收起 MacClippy 悬浮卡片坞（可在偏好设置中修改） |
| **`直接打字`** | 检索历史记录中的已索引内容 |
| **`⏎` (Return)** | 搜索框内进入结果，结果中粘贴选中项 |
| **`⇧ ⏎`** | 切换纯文本与原格式粘贴 |
| **`空格 Space`** | 在结果中开关预览，在搜索框中正常输入空格 |
| **`⌘ 1` – `⌘ 9`** | 快速粘贴对应序号的剪贴项 |
| **`⌘ C`** | 将选中卡片拷贝到系统剪贴板（不关闭卡片坞） |
| **`⌘ A`** | 在历史／固定板结果中选择全部匹配项；搜索框中为全选文字 |
| **`⇧⌥⌘C`** | 跳过下一次剪贴板变化的采集 |
| **`⌘ P`** | 为选中条目选择目标固定板 |
| **`Tab` / `Shift-Tab`** | 在搜索框和结果之间切换，保留查询 |
| **`⌘ F` / `⌘ K`** | 聚焦搜索框 |
| **`⌘ ⌥ V`** | 查看条目详情，在详情中按 `⌘E` 编辑 |
| **`⌘ S` / `⌘ Return`** | 编辑时保存／保存并粘贴 |
| **`⌘ ⌫` (退格)** | 从历史删除选中项，包括它们在固定板中的关联 |
| **`←` / `→`** | 在剪贴板卡片之间左右切换选择 |
| **`Esc`** | 分层退出；搜索中先清查询，再关闭卡片坞 |

---

## 苹果通用剪贴板 (Universal Clipboard)

如果 macOS 通用剪贴板把附近 Apple 设备复制的内容放到本机剪贴板，MacClippy 可以将其保存为本地历史记录。MacClippy 不会在不同 Mac 之间同步历史记录或加密密钥。

备份包含加密后的应用数据，但不会导出钥匙串密钥。恢复数据需要原安装仍保有的密钥；备份不能把历史记录或密钥迁移到另一台设备。

---

## 下载与安装指南

### 1. 下载官方预编译安装包
`main` 分支会生成每日构建，`vX.Y.Z` 标签会生成正式版本；两者都必须先通过同一提交 SHA 的 CI 检查：

- **下载 DMG 或 ZIP 发布包**：
  - [正式发布页面 Releases](https://github.com/wangm12/mac-clippy/releases)（稳定发布版本）
  - [每日构建页面 Nightly](https://github.com/wangm12/mac-clippy/releases/tag/nightly)（最新持续集成包）
- 从发布页面选择带版本号的 DMG 或 ZIP。打开 DMG 后，将 `MacClippy.app` 拖入 **Applications（应用程序）** 文件夹。

### 2. 权限授予与 Gatekeeper 说明
- **辅助功能权限 (Accessibility)**：用于自动粘贴（通过 `CGEvent` 发送粘贴快捷键）与片段键入展开。请在 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选允许。
- **输入监控权限 (Input Monitoring)**：用于片段触发词的全局键入监听；可在 **系统设置 → 隐私与安全性 → 输入监控** 中授权。权限页还提供全局快捷键相关提示。
- **Gatekeeper 首次打开提示**：未使用 Developer ID 签名和公证的构建可能触发 Gatekeeper 警告。
  - 先尝试打开应用，然后前往 **系统设置 → 隐私与安全性** 选择 **“仍要打开”**，再确认提示。参见[Apple 官方说明](https://support.apple.com/zh-cn/102445)。

### 3. 从源码构建

系统环境要求：
- 应用运行环境：macOS 14.0 或更高版本（Sonoma 或更新版本）
- 源码构建环境：Xcode 16.3+、Swift 6.1+，并使用该 Xcode 支持的 macOS 版本
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 与 [SwiftLint](https://github.com/realm/SwiftLint)（工程内脚本会自动安装固定版本）

```sh
# 克隆代码仓库
git clone https://github.com/wangm12/mac-clippy.git
cd mac-clippy

# 安装指定版本工具链 (XcodeGen 与 SwiftLint)
./scripts/install-pinned-tools.sh

# 生成 Xcode 工程文件
make generate

# 编译 Debug 版本
make build

# 打包 DMG 与 ZIP 到 dist/ 目录（配置 Developer ID 证书后才会签名）
make dmg
```

---

## 开发与测试常用命令

参见 [CI 与发布流程说明](docs/release-process.md)，了解同一提交的发布门禁、版本规则和最低系统运行测试。

```sh
make help           # 列出可用的开发与发布目标
make generate       # 从 project.yml 重新生成 MacClippy.xcodeproj
make build          # 编译 Debug 应用程序
make test           # 运行 Package 测试和 MacClippyTests 单元测试；不运行 UI 测试
make test-scripts   # 运行构建与发布脚本测试
make test-scale     # 显式启用 Package 与 Runtime 规模测试夹具
make test-stress    # 运行生命周期压力测试
make test-tsan      # 使用 Thread Sanitizer 运行 Package 测试
make test-app-tsan  # 使用 Thread Sanitizer 运行 MacClippyTests 单元测试
make lint           # 依据基准线执行 SwiftLint 代码质量检查
make dmg            # 打包 DMG 与 ZIP（配置 Developer ID 证书后才会签名）
make ci             # 运行 CI 构建和验证流程
make clean          # 清理受管理的缓存、测试结果和归档；保留 dist/ 与审查证据
```

---

## 架构与技术栈设计

```text
MacClippy/
├── MacClippy/             # AppKit / SwiftUI 界面、悬浮卡片坞、状态栏与偏好设置
├── MacClippyKit/          # 核心底层库：存储层、FTS5 检索、OCR 引擎、文本变换、加密
├── MacClippyTests/        # 应用程序级 XCTest 单元与集成测试
├── MacClippyUITests/      # 界面动效交互、卡片拖拽与粘贴模拟自动化测试
├── scripts/               # 证书自签名、DMG/ZIP 打包封装与环境验证脚本
└── project.yml            # 声明式 XcodeGen 工程管理定义
```

- **图形界面**：AppKit 定制窗口、面板和输入路由，结合 SwiftUI 卡片、预览、详情与设置视图，以及原生材质、Core Animation 和拖拽交互。
- **持久化存储**：SQLite 3 结合 WAL 日志模式，通过现代 Swift 数据库框架 [GRDB.swift](https://github.com/groue/GRDB.swift) 进行高效异步操作。
- **全文检索引擎**：SQLite FTS5 引擎，结合定制 Unicode 分词器及 CJK 连续字串匹配算法。
- **OCR 识别引擎**：使用 Apple Vision 框架 (`VNRecognizeTextRequest`) 在设备本地识别文字。
- **载荷加密**：CryptoKit AES-256-GCM 使用软件生成的 256 位密钥；密钥存放于 Data Protection Keychain，并设置为 `WhenUnlockedThisDeviceOnly`。这不是 Secure Enclave 密钥。

---

## 隐私与数据安全说明

MacClippy 将数据保存在本地 Mac：

```text
~/Library/Application Support/MacClippy/
```

- MacClippy 没有账号式历史记录同步。Apple 通用剪贴板可以把复制内容放到本机剪贴板，MacClippy 随后在本机保存副本。
- 剪贴板载荷信封和附件/图片载荷字节会加密。SQLite 数据库本身并未整体加密：可搜索预览、OCR 文字、全文索引词、自定义标签和片段触发词、来源应用信息、内容类型、时间戳及其他运行元数据以明文保留，以支持搜索和展示。
- 加密密钥保存在当前安装的钥匙串中，不包含在备份里。恢复数据需要原安装的密钥；备份不提供跨设备密钥迁移。
- 默认排除内置密码管理器来源以及隐藏／临时剪贴板类型；Capture All 会改变类型排除行为，详见上文隐私规则。未被识别或排除的敏感内容仍可能进入历史。
- 设置中的“删除未固定历史”保留固定项；如需删除固定项，请显式从历史永久删除，或先解除固定再清理。

---

## 开源协议

本项目尚未发布公开许可证。

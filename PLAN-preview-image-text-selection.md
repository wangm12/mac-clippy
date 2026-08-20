# 图片 Preview OCR 文字选择与复制计划

> Owner: mingjie-father  
> Status: implementation complete; manual UI/TCC validation pending  
> Platform: 原生 macOS 14+  
> Scope: 图片 Preview 中的 OCR 文字直接拖选、复制和 fallback 体验

## 1. 目标与最终体验

- 用户打开截图 Preview 后，可以直接在图片上的文字区域拖动选择文字。
- 支持单行、跨行、反向拖选、中文、英文、emoji 和常见代码截图。
- 有 OCR 选区时，`⌘C` 只复制选中文字；无选区时保持现有图片 Copy 行为。
- 现有 `Copy` 保持原语义：复制原始图片。
- 新增 `Copy Text`：复制完整 OCR 文字。
- OCR 失败不影响图片显示和原始图片复制。
- 图片 Preview 首次显示不等待 OCR；OCR 在后台异步加载。
- Preview 关闭、切换图片或 Runtime 停止后，旧 OCR 结果不能更新当前 Preview。
- 不修改数据库 schema、加密格式或 Core 层职责，不上传图片和 OCR 内容。

Apple 的 `ImageAnalysisInteraction` 当前只支持 iOS、iPadOS、Mac Catalyst 和 visionOS，不适合作为原生 macOS 14 方案。因此使用 Vision + AppKit 自建选择层。

参考：

- https://developer.apple.com/documentation/visionkit/imageanalysisinteraction
- https://developer.apple.com/documentation/vision/recognizing-text-in-images
- https://developer.apple.com/documentation/vision/locating-and-displaying-recognized-text

## 2. 关键架构决策

### 2.1 使用单一 selection coordinator

不使用“每行一个透明 `NSTextView`”作为最终架构。该方式只能较可靠地支持单行选择，无法自然处理跨行 selection、统一 `Cmd+C`、反向拖选和非 key Preview panel。

采用单一 AppKit selection coordinator：

```text
Vision text-range geometry
    -> image coordinate mapper
    -> one custom NSView hit-testing layer
    -> unified UTF-16 selection range
    -> selectedText
    -> DockController handles Cmd+C
```

可以使用 TextKit 计算字符位置，但 selection 状态、跨行聚合、复制和绘制高亮由 coordinator 统一管理。

### 2.2 保持 Dock 的 keyboard ownership

当前 Preview panel 不是 key window，不能依赖 Preview 内部的 first responder 自然接收 `Cmd+C`。

默认保持 Dock 为 key window：

- 文字 overlay 负责鼠标 hit testing 和 selection state。
- Dock Controller 的 keyboard router 查询 selection coordinator。
- 有 OCR 选区时，`Cmd+C` 调用 coordinator 的 `copySelectedText()`。
- 无 OCR 选区时，保留现有图片 Copy 行为。
- Escape、Space、左右箭头继续走现有 Preview 路由。

不在用户开始拖选时临时切换 Preview 为 key window，避免破坏现有 Dock 快捷键、关闭行为和焦点恢复逻辑。

### 2.3 Preview OCR 独立于 Runtime 持久化 OCR

后台 OCR 继续负责数据库 `ocrText` 和 FTS projection；Preview OCR 只生成临时 layout，不写数据库。

Preview OCR 生命周期绑定：

```text
previewSessionGeneration + recordID + contentFingerprint
```

每次 Preview 打开或导航时创建新的 request generation。关闭 Preview、切换记录、重载图片时取消旧 task。completion 回 MainActor 前必须验证 generation、recordID 和 Preview 可见状态。

## 3. OCR 数据模型与服务

### 3.1 Layout 模型

Layout DTO 保留在 Platform/App 边界，不进入 Core：

```swift
struct MacClippyOCRNormalizedRect: Equatable, Sendable {
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double
}

struct MacClippyOCRCharacter: Equatable, Sendable {
    let text: String
    let boundingBox: MacClippyOCRNormalizedRect
}

struct MacClippyOCRTextLine: Equatable, Sendable {
    let text: String
    let boundingBox: MacClippyOCRNormalizedRect
    let characters: [MacClippyOCRCharacter]
}

struct MacClippyOCRResult: Equatable, Sendable {
    let lines: [MacClippyOCRTextLine]
    let fullText: String
}
```

如果 Vision 对某些文字不能稳定提供字符级 geometry，保留 line result，但 UI 明确降级为整行选择；不能把整行 bounding box 伪装成字符级精确选择。

### 3.2 OCR API

扩展 `MacClippyOCRService`：

```swift
func recognizeLayout(data: Data) async throws -> MacClippyOCRResult
func recognizeLayout(image: CGImage) async throws -> MacClippyOCRResult
```

现有 `recognize(data:) -> String` 保留，通过 `recognizeLayout` 返回 `fullText`，避免破坏后台 OCR、搜索和已有测试。

OCR 规则：

- 继续使用 Vision `.accurate`。
- 保持当前中英文识别配置，避免本次 UI 功能改变搜索结果。
- 按从上到下、从左到右稳定排序。
- 过滤空 observation 和纯空白结果。
- 通过 recognized text range 计算字符/文本片段 bounding box。
- Vision 执行必须在后台，不阻塞 MainActor。
- 错误、取消和 diagnostics 不包含 OCR 正文或图片数据。

### 3.3 Runtime 注入

在 Runtime 增加可测试的 layout provider，但不把 UI selection 类型暴露到 Core：

```swift
let recognizeOCRLayout: @Sendable (Data) async throws -> MacClippyOCRResult
```

生产环境使用 `MacClippyOCRService`；测试使用 fake provider 控制延迟、成功、失败和取消。

## 4. 图片 Preview 与坐标转换

### 4.1 共享 bounded image asset

Preview session 只生成一份 bounded `CGImage`，供图片显示和 OCR 共用，避免原始 Data 被重复解码：

- 使用 ImageIO thumbnail 和 `kCGImageSourceCreateThumbnailWithTransform`。
- 继续限制最大像素尺寸。
- 不把原始大图片放入 OCR cache。
- OCR cache 只保存轻量 layout DTO。
- Preview 关闭后释放 image、layout、selection 和 task 引用。

### 4.2 Geometry

自定义 image container 负责计算实际 displayed image rect：

- 处理横向、纵向和正方形图片。
- 处理 aspect-fit 的 letterbox 区域。
- Vision 坐标原点在左下，AppKit overlay 显示坐标需要显式转换 Y 轴。
- 窗口 resize、图片导航和 Retina scale 变化时重新布局。
- letterbox 区域不能命中 OCR selection。
- 使用同一份已处理方向的 `CGImage`，避免 EXIF orientation 导致 overlay 偏移。

## 5. Selection Coordinator

新增 App 内部 selection host，不进入 Core：

```swift
protocol MacClippyPreviewTextSelectionHost: AnyObject {
    var hasSelectedText: Bool { get }
    var selectedText: String? { get }
    func copySelectedText()
}
```

职责：

- 将鼠标位置映射到最近字符或文本片段。
- 记录 anchor 和 active endpoint。
- 支持同一行、跨行、反向和取消选择。
- 使用 UTF-16 offset，正确处理中文、emoji 和混合文本。
- 绘制系统 accent color 半透明 selection highlight。
- 通过 callback 同步 `selectedText` 和 `hasSelectedText`。
- 选区为空时不写 pasteboard。
- `copySelectedText()` 通过现有统一 feedback/pasteboard 路径执行。

如果字符级 geometry 缺失：

- 命中该行即选中整行；
- UI 仍然可复制；
- 不宣称字符级精确选择。

## 6. Copy、Fallback 与无障碍

### Copy 行为

- `Copy`：复制原始图片。
- `Copy Text`：复制全部 `fullText`，OCR 成功后显示或启用。
- 有选区时 `Cmd+C`：复制当前选区。
- 无选区时 `Cmd+C`：继续执行原始图片 Copy。
- 复制成功使用现有 toast/feedback，不记录正文。

### OCR fallback

- OCR layout 失败时仍显示图片。
- 如果历史 metadata 已有 `ocrText`，显示可展开的 `Recognized Text` selectable fallback。
- fallback 使用现有 `NSTextView`，不依赖图片 overlay。
- 没有 OCR 文本时不弹错误，只保留图片预览和 Copy。

### Accessibility

- 图片提供 `Clipboard image preview` label。
- OCR 可用时提供 `Recognized text available` 状态。
- selection host 提供可读的 selected state 和 Copy action。
- 不把完整 clipboard body 或 OCR 正文放入默认图片 label。
- fallback text 使用原生 selectable text accessibility。
- VoiceOver、颜色、高亮和 selected state 不能只依赖颜色。
- Reduce Motion 下 overlay 直接进入最终状态，不使用 stagger、bounce、scale 或长 fade。

## 7. 测试计划

### OCR Service

- [x] invalid image 返回 `.invalidImage`。
- [x] 多行 OCR 返回稳定排序和 bounding box。
- [x] 中英文混合、代码标点和缩进保留合理结果。
- [x] 字符/文本片段 geometry 与 fullText range 对齐。
- [x] 空 observation 被过滤。
- [x] 旋转图片和 EXIF orientation 坐标正确（ImageIO thumbnail transform；真实设备仍需 smoke）。
- [x] cancellation 不执行过期 completion。
- [x] 既有 `recognize(data:)` 行为不回归。

### Geometry / Selection

- [x] aspect-fit 横图、竖图、正方形和 letterbox（自动化 geometry 覆盖横/竖/空 bounds）。
- [x] Vision 左下坐标转换到 AppKit overlay 正确。
- [x] window resize 后文字位置仍对齐（layout 从当前 bounds 即时计算；真实 resize smoke pending）。
- [x] 单行拖选、跨行拖选、反向拖选（selection policy 覆盖跨行/反向；真实 mouse smoke pending）。
- [x] 中文、emoji、英文和代码 grapheme selection 正确。
- [x] 缺失字符 geometry 时整行 fallback 正确。
- [x] 空白区域不能选中文字（hit-test 只接受 image/line rect；真实 UI pending）。

### App / Keyboard

- [x] Preview 非 key window 的 `Cmd+C` 由 Dock Controller 显式路由（真实 panel smoke pending）。
- [x] 有 OCR selection 时 `Cmd+C` 只复制选区（controller route implemented）。
- [x] 无 selection 时 Copy 仍复制原始图片。
- [x] `Copy Text` 复制完整 OCR 文本。
- [x] A → B 导航不会把 A 的 OCR 显示到 B（content identity/fingerprint）。
- [x] 关闭 Preview 后 OCR completion 不更新 UI（root reset + task cancellation fences）。
- [x] 同一 RecordID 内容变化时旧 layout 不复用。
- [x] OCR 失败时图片仍可显示和复制。
- [x] fallback OCR 文本可选择复制。

### Performance / Lifecycle

- [x] 图片首次显示不等待 OCR。
- [x] OCR 不在 MainActor 执行。
- [x] Preview 关闭和导航时 task 取消。
- [x] cache 有 count/cost limit（8 entries / 2MB estimated layout cost）。
- [x] image、layout、selection 有 bounded lifetime；原始图片不进入 cache。
- [ ] 大图、4K/8K 截图下没有明显内存峰值或拖选卡顿（需 Instruments/真实数据）。
- [ ] 选择和 Preview 动画期间没有明显 frame hitch（需 Core Animation/真实设备）。

## 8. 实施顺序与验收

1. AppKit spike：验证非 key Preview panel 的鼠标拖选、Controller `Cmd+C` 路由和关闭/导航行为。
2. Vision layout DTO：加入 text range/character geometry，并保持现有 String OCR API。
3. Shared image asset：display 和 OCR 共用 bounded `CGImage`。
4. Selection coordinator：完成 hit testing、统一 selection、highlight 和 copy。
5. Preview OCR coordinator：加入 generation、recordID、fingerprint、取消和缓存。
6. Copy Text、fallback、VoiceOver、Reduce Motion。
7. 完成单元测试、App XCTest、性能测量和真实 App 手动验证。

Definition of Done：

- [ ] 用户可以直接在真实截图文字上拖选并复制（代码完成；本机 UI smoke pending）。
- [x] `Copy`、`Copy Text` 和 `Cmd+C` 语义明确且互不破坏。
- [x] Preview OCR 不写数据库，不污染 Runtime lifecycle。
- [x] 原始图片始终可预览和复制（自动化 path/build 覆盖；真实设备 pending）。
- [x] macOS 14+ 编译和现有 package tests 通过。
- [x] OCR 取消、导航、关闭、缓存和错误路径有代码保护与回归测试覆盖。
- [ ] 未获得真实 Instruments、VoiceOver、TCC 或 release 签名证据时，不宣称这些 gate 已通过。

## 9. 风险与回滚

| 风险 | 保护措施 |
|---|---|
| 字符级 geometry 在部分图片不可用 | 降级为整行选择，并在测试中明确覆盖 |
| 非 key Preview 接收不到预期键盘事件 | 保持 Dock key，由 Controller 显式路由 selection copy |
| OCR 结果污染新 Preview | generation + recordID + fingerprint 三重校验 |
| OCR 额外解码造成卡顿 | shared bounded CGImage 和 layout-only cache |
| selection overlay 影响原始图片复制 | overlay 只处理有命中 selection 的输入；无 selection 走原路径 |
| 新 API 扩大 Core 边界 | layout DTO 保持 Platform/App internal，不改 Core 依赖方向 |

import AppKit
import CoreGraphics
import ImageIO
import MacClippyCore
import MacClippyPlatform
import SwiftUI

enum MacClippyDockPreviewTextCopyPolicy {
    static func textToCopy(selectedText: String?, fullText: String?) -> String? {
        if let selectedText, !selectedText.isEmpty {
            return selectedText
        }
        guard let fullText, !fullText.isEmpty else { return nil }
        return fullText
    }

    static func isSelection(selectedText: String?) -> Bool {
        guard let selectedText else { return false }
        return !selectedText.isEmpty
    }
}
extension MacClippyDockPreviewContent {
    var identity: String {
        switch self {
        case .loading:
            return "loading"
        case let .text(id, _, _):
            return "text:\(id.rawValue)"
        case let .richText(id, _, _):
            return "richText:\(id.rawValue)"
        case let .color(id, _, _):
            return "color:\(id.rawValue)"
        case let .image(id, _):
            // Clipboard records are immutable. The record ID is therefore a
            // stable identity and avoids hashing an entire screenshot while
            // SwiftUI recomputes the preview body.
            return "image:\(id.rawValue)"
        case let .files(urls):
            return "files:\(urls.map(\.absoluteString).joined(separator: "|"))"
        case .error:
            return "error"
        }
    }

    var textValue: String? {
        switch self {
        case let .text(_, value, _), let .color(_, value, _):
            return value
        case let .richText(_, _, plain):
            return plain
        case .loading, .image, .files, .error:
            return nil
        }
    }

    func footerText(characterCount: Int) -> String? {
        switch self {
        case let .color(_, _, swatch):
            return swatch.hex
        case .loading, .error:
            return nil
        case .files:
            return nil
        case .text, .richText, .image:
            return characterCount > 0 ? "\(characterCount) characters" : nil
        }
    }
}

enum MacClippyOCRSelectionAppearance {
    // Keep the source screenshot readable: the outline carries selection
    // feedback while the fill remains nearly transparent.
    static let selectionColor = NSColor.controlAccentColor
    static let characterFillOpacity: CGFloat = 0.12
    static let characterStrokeOpacity: CGFloat = 0.92
    static let fallbackLineFillOpacity: CGFloat = 0.08
    static let fallbackLineStrokeOpacity: CGFloat = 0.88

    static func characterHighlightRect(_ rect: NSRect) -> NSRect {
        guard rect.width > 2, rect.height > 2 else { return rect }
        let horizontalInset = min(1, rect.width * 0.08)
        let verticalInset = min(1, rect.height * 0.10)
        return rect.insetBy(dx: horizontalInset, dy: verticalInset)
    }

    static func fallbackLineHighlightRect(_ rect: NSRect) -> NSRect {
        guard rect.width > 2, rect.height > 2 else { return rect }
        return rect.insetBy(dx: 1, dy: min(2, rect.height * 0.12))
    }
}

private enum MacClippyPreviewImageDownsampler {
    static func image(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private actor MacClippyPreviewOCRLayoutCache {
    static let shared = MacClippyPreviewOCRLayoutCache()

    private struct Entry {
        let result: MacClippyOCRResult
        let cost: Int
    }

    private let countLimit = 8
    private let costLimit = 2 * 1024 * 1024
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var totalCost = 0

    func result(for key: String) -> MacClippyOCRResult? {
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.result
    }

    func insert(_ result: MacClippyOCRResult, for key: String) {
        let cost = Self.estimatedCost(of: result)
        guard cost <= costLimit else { return }
        if let existing = entries.removeValue(forKey: key) {
            totalCost -= existing.cost
            order.removeAll { $0 == key }
        }
        entries[key] = Entry(result: result, cost: cost)
        order.append(key)
        totalCost += cost
        trimToLimits()
    }

    private func trimToLimits() {
        while entries.count > countLimit || totalCost > costLimit {
            guard let oldest = order.first,
                  let removed = entries.removeValue(forKey: oldest) else { return }
            order.removeFirst()
            totalCost -= removed.cost
        }
    }

    private static func estimatedCost(of result: MacClippyOCRResult) -> Int {
        result.lines.reduce(0) { cost, line in
            cost
                + line.text.utf8.count
                + line.characters.count * 64
                + 64
        }
    }
}

struct MacClippyDockPreviewImage: View {
    let id: RecordID
    let data: Data
    let storedOCRText: String?
    let recognizeOCRLayout: (@Sendable (CGImage) async throws -> MacClippyOCRResult)?
    let onOCRResult: ((MacClippyOCRResult?) -> Void)?
    let onSelectionChanged: ((String?) -> Void)?
    let onCopySelection: ((String) -> Void)?

    @State private var image: CGImage?
    @State private var ocrResult: MacClippyOCRResult?
    @State private var failed = false
    @State private var ocrFailed = false
    @State private var selectedText: String?
    @State private var loadedImageFingerprint: String?
    @State private var ocrAttempt = 0

    private var contentFingerprint: String {
        // History entries are immutable and the record ID is already the
        // identity used by the preview controller. Avoid hashing every image
        // byte whenever SwiftUI reevaluates this view.
        id.rawValue
    }

    private var taskID: String {
        "\(id.rawValue):\(contentFingerprint):\(ocrAttempt)"
    }

    private var ocrCacheKey: String {
        contentFingerprint
    }

    var body: some View {
        VStack(spacing: 8) {
            if failed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Image preview unavailable")
            } else if image != nil {
                ZStack(alignment: .bottomLeading) {
                    MacClippyDockPreviewImageSelection(
                        image: image,
                        ocrResult: ocrResult,
                        onSelectionChanged: { value in
                            selectedText = value
                            onSelectionChanged?(value)
                        },
                        onCopySelection: onCopySelection
                    )
                    if let selectedText, !selectedText.isEmpty {
                        Label("Text selected · ⌘C to copy", systemImage: "text.cursor")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(
                                        Color(nsColor: MacClippyOCRSelectionAppearance.selectionColor)
                                            .opacity(0.35),
                                        lineWidth: 1
                                    )
                            }
                            .padding(10)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Text selected. Press Command-C to copy.")
                    }
                    if ocrFailed {
                        Button {
                            ocrAttempt &+= 1
                        } label: {
                            Label("Retry text recognition", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(10)
                        .accessibilityLabel("Retry text recognition")
                    } else if ocrResult == nil {
                        Label("Recognizing text…", systemImage: "text.viewfinder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                            .accessibilityLabel("Recognizing text")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Clipboard image preview")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading image")
            }

            if ocrFailed, let storedOCRText, !storedOCRText.isEmpty {
                MacClippyDockPreviewTextView(
                    text: storedOCRText,
                    monospaced: false,
                    foregroundColor: .labelColor
                )
                .frame(maxHeight: 120)
                .overlay(alignment: .topLeading) {
                    Text("Recognized Text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }
        }
        .task(id: taskID) {
            ocrResult = nil
            selectedText = nil
            failed = false
            ocrFailed = false
            onOCRResult?(nil)
            let fingerprint = contentFingerprint
            if loadedImageFingerprint != fingerprint {
                image = nil
                loadedImageFingerprint = nil
            }

            if image == nil {
                let sourceData = data
                let decodeTask = Task.detached(priority: .userInitiated) {
                    MacClippyPreviewImageDownsampler.image(sourceData, maxPixelSize: 2_048)
                }
                let decodedImage = await withTaskCancellationHandler(operation: {
                    await decodeTask.value
                }, onCancel: {
                    decodeTask.cancel()
                })
                guard !Task.isCancelled else { return }
                guard let decodedImage else {
                    failed = true
                    return
                }
                image = decodedImage
                loadedImageFingerprint = fingerprint
            }

            guard let recognizeOCRLayout,
                  let image else {
                ocrFailed = true
                return
            }
            if let cachedResult = await MacClippyPreviewOCRLayoutCache.shared.result(for: ocrCacheKey) {
                guard !Task.isCancelled else { return }
                ocrResult = cachedResult.fullText.isEmpty ? nil : cachedResult
                ocrFailed = cachedResult.fullText.isEmpty
                onOCRResult?(ocrResult)
                return
            }
            do {
                let result = try await recognizeOCRLayout(image)
                guard !Task.isCancelled else { return }
                await MacClippyPreviewOCRLayoutCache.shared.insert(result, for: ocrCacheKey)
                guard !Task.isCancelled else { return }
                ocrResult = result.fullText.isEmpty ? nil : result
                ocrFailed = result.fullText.isEmpty
                onOCRResult?(ocrResult)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                ocrFailed = true
                onOCRResult?(nil)
            }
        }
    }
}

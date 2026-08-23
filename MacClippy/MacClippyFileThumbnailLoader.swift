import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

import MacClippyCore

enum MacClippyFileThumbnailPolicy {
    static func usesImageIO(for url: URL) -> Bool {
        MacClippyFilePresentation.mediaKind(for: url) == .image
    }
}

/// Raster files use ImageIO. Quick Look's best-representation path talks to
/// WindowServer and freezes fullscreen Spaces for WeChat/Library JPEGs.
enum MacClippyFileThumbnailLoader {
    private static let cache = MacClippyFileThumbnailCache()
    private static let flights = MacClippyFileThumbnailFlights()

    static func image(for url: URL, pointSize: CGSize) async -> CGImage? {
        let key = cacheKey(url: url, pointSize: pointSize)
        if let cached = cache.object(for: key) {
            return cached
        }
        let image = await flights.takeoff(key: key) {
            await render(url: url, pointSize: pointSize)
        }
        if let image {
            cache.setObject(image, for: key)
        }
        return Task.isCancelled ? nil : image
    }

    private static func cacheKey(url: URL, pointSize: CGSize) -> String {
        "\(url.path)|\(Int(pointSize.width.rounded()))x\(Int(pointSize.height.rounded()))"
    }

    private static func render(url: URL, pointSize: CGSize) async -> CGImage? {
        if MacClippyFileThumbnailPolicy.usesImageIO(for: url) {
            return imageIOThumbnail(url: url, pointSize: pointSize, scale: 2)
        }
        return workspaceIcon(for: url, pointSize: pointSize)
    }

    private static func imageIOThumbnail(url: URL, pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let maxPixel = max(1, Int(max(pointSize.width, pointSize.height) * scale))
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func workspaceIcon(for url: URL, pointSize: CGSize) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = pointSize
        guard let data = icon.tiffRepresentation,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private actor MacClippyFileThumbnailFlights {
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    func takeoff(
        key: String,
        work: @escaping @Sendable () async -> CGImage?
    ) async -> CGImage? {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task.detached(priority: .utility) {
            await work()
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}

private final class MacClippyFileThumbnailCache: @unchecked Sendable {
    private let lock = NSLock()
    private let countLimit = 48
    private let costLimit = 32 * 1_024 * 1_024
    private var order: [String] = []
    private var images: [String: CGImage] = [:]
    private var costs: [String: Int] = [:]
    private var totalCost = 0

    func object(for key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return image
    }

    func setObject(_ image: CGImage, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        let cost = max(1, image.width * image.height * 4)
        if let existingCost = costs[key] {
            totalCost -= existingCost
        } else {
            order.append(key)
        }
        images[key] = image
        costs[key] = cost
        totalCost += cost
        while (images.count > countLimit || totalCost > costLimit), let oldest = order.first {
            order.removeFirst()
            images.removeValue(forKey: oldest)
            if let removedCost = costs.removeValue(forKey: oldest) {
                totalCost -= removedCost
            }
        }
    }
}

struct MacClippyFileThumbnail: View, Equatable {
    let url: URL
    let pointSize: CGSize

    @State private var image: CGImage?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.pointSize == rhs.pointSize
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: MacClippyDockCardMetrics.imagePreviewRadius,
                            style: .continuous
                        )
                    )
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        MacClippyDockPreviewFileIcon(url: url)
                    }
            }
        }
        .task(id: "\(url.path)|\(Int(pointSize.width))x\(Int(pointSize.height))") {
            image = nil
            let loaded = await MacClippyFileThumbnailLoader.image(for: url, pointSize: pointSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

enum MacClippyFileByteCount {
    static func total(for urls: [URL]) -> Int64 {
        urls.reduce(into: 0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
    }

    static func label(for urls: [URL]) -> String? {
        let total = total(for: urls)
        guard total > 0 else { return nil }
        return MacClippyFilePresentation.byteCountLabel(bytes: total)
    }
}

struct MacClippyFileImagePreview: View {
    let url: URL

    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(MacClippyFilePresentation.displayName(for: url))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: url.path) {
            image = nil
            let loaded = await MacClippyFileThumbnailLoader.image(
                for: url,
                pointSize: CGSize(width: 2_048, height: 2_048)
            )
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct MacClippyFileByteCountLabel: View {
    let urls: [URL]
    var font: Font = MacClippyDockCardMetrics.contentFont
    var color: Color = MacClippyDockTheme.contentMutedColor

    @State private var label: String?

    var body: some View {
        Group {
            if let label {
                Text(label)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
        }
        .task(id: urls.map(\.path).joined(separator: "|")) {
            let resolved = await Task.detached(priority: .utility) {
                MacClippyFileByteCount.label(for: urls)
            }.value
            guard !Task.isCancelled else { return }
            label = resolved
        }
    }
}

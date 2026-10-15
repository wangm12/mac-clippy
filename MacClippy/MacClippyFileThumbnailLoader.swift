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

enum MacClippyFileThumbnailRasterPolicy {
    static let maximumPointDimension: CGFloat = 1_536
    static let maximumPixelDimension = 3_072
    static let maximumDecodedBytes = 36 * 1_024 * 1_024

    static func normalizedPointSize(_ size: CGSize) -> CGSize {
        let width = safeDimension(size.width)
        let height = safeDimension(size.height)
        let longestEdge = max(width, height)
        let scale = min(1, maximumPointDimension / longestEdge)
        return CGSize(width: max(1, width * scale), height: max(1, height * scale))
    }

    static func cacheDimension(_ dimension: CGFloat) -> Int {
        Int(safeDimension(dimension).rounded())
    }

    static func maximumPixelSize(for size: CGSize, scale: CGFloat) -> Int {
        let normalized = normalizedPointSize(size)
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let pixels = max(normalized.width, normalized.height) * safeScale
        return Int(min(CGFloat(maximumPixelDimension), max(1, pixels)).rounded(.up))
    }

    private static func safeDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return min(maximumPointDimension, value)
    }
}

/// Raster files use ImageIO. Quick Look's best-representation path talks to
/// WindowServer and freezes fullscreen Spaces for WeChat/Library JPEGs.
enum MacClippyFileThumbnailLoader {
    private static let service = MacClippyFileThumbnailService(
        imageIODecoder: { url, pointSize, isCancelled in
            imageIOThumbnail(
                url: url,
                pointSize: pointSize,
                scale: 2,
                isCancelled: isCancelled
            )
        },
        workspaceIconRenderer: { url, pointSize, isCancelled in
            workspaceIcon(for: url, pointSize: pointSize, isCancelled: isCancelled)
        }
    )

    static func cacheKey(url: URL, pointSize: CGSize) -> String {
        let normalized = MacClippyFileThumbnailRasterPolicy.normalizedPointSize(pointSize)
        let width = MacClippyFileThumbnailRasterPolicy.cacheDimension(normalized.width)
        let height = MacClippyFileThumbnailRasterPolicy.cacheDimension(normalized.height)
        return "\(url.path)|\(width)x\(height)"
    }

    static func resetForSessionEnd() {
        service.resetForSessionEnd()
    }

    static func cachedImage(for url: URL, pointSize: CGSize) -> CGImage? {
        service.cachedImage(forKey: cacheKey(url: url, pointSize: pointSize))
    }

    static func image(for url: URL, pointSize: CGSize) async -> CGImage? {
        await service.image(
            for: url,
            pointSize: MacClippyFileThumbnailRasterPolicy.normalizedPointSize(pointSize)
        )
    }

    private static func imageIOThumbnail(
        url: URL,
        pointSize: CGSize,
        scale: CGFloat,
        isCancelled: @Sendable () -> Bool
    ) -> CGImage? {
        guard !isCancelled() else { return nil }
        let maxPixel = MacClippyFileThumbnailRasterPolicy.maximumPixelSize(
            for: pointSize,
            scale: scale
        )
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        guard !isCancelled() else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        return isCancelled() ? nil : image
    }

    @MainActor
    private static func workspaceIcon(
        for url: URL,
        pointSize: CGSize,
        isCancelled: @Sendable () -> Bool
    ) -> CGImage? {
        guard !isCancelled() else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard !isCancelled() else { return nil }
        return MacClippySourceAppIcon.rasterized(
            icon,
            pointSize: max(pointSize.width, pointSize.height)
        )
    }
}

struct MacClippyFileThumbnail: View, Equatable {
    let url: URL
    let pointSize: CGSize

    @State private var image: CGImage?
    @State private var loadedIdentity: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url == rhs.url && lhs.pointSize == rhs.pointSize
    }

    private var identity: String {
        MacClippyFileThumbnailLoader.cacheKey(url: url, pointSize: pointSize)
    }

    var body: some View {
        let displayed = MacClippyThumbnailDisplayPolicy.displayed(
            loadedIdentity: loadedIdentity,
            currentIdentity: identity,
            image: image,
            cached: MacClippyFileThumbnailLoader.cachedImage(for: url, pointSize: pointSize)
        )
        Group {
            if let displayed {
                Image(decorative: displayed, scale: 1, orientation: .up)
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
        .task(id: identity) {
            if MacClippyThumbnailRetainPolicy.shouldClearDisplayedImage(
                displayedIdentity: loadedIdentity,
                loadingIdentity: identity
            ) {
                image = nil
            }
            loadedIdentity = identity
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

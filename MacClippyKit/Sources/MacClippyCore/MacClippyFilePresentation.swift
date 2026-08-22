import Foundation

/// Shared labels for Finder file copies so capture preview, dock cards,
/// Space preview, search, and dedup stay on one contract. The card title
/// matches Paste ("1 file" / "N files"); the store preview uses the
/// filename so two different single-file copies do not collapse.
public enum MacClippyFilePresentation {
    public enum MediaKind: Equatable, Sendable {
        case image
        case movie
        case other
    }

    private static let imageExtensions: Set<String> = [
        "bmp", "gif", "heic", "heif", "ico", "jfif", "jpe", "jpeg", "jpg",
        "png", "tif", "tiff", "webp"
    ]
    private static let movieExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4"
    ]

    /// Path extension only. Do not call `resourceValues` here: WeChat and
    /// other container copies can stall the main thread on file coordination.
    public static func mediaKind(for url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return .image
        }
        if movieExtensions.contains(ext) {
            return .movie
        }
        return .other
    }

    public static func title(fileCount: Int) -> String {
        fileCount == 1 ? "1 file" : "\(max(fileCount, 0)) files"
    }

    public static func storePreview(for urls: [URL]) -> String {
        guard !urls.isEmpty else { return title(fileCount: 0) }
        if urls.count == 1 {
            return displayName(for: urls[0])
        }
        let first = displayName(for: urls[0])
        return first.isEmpty ? title(fileCount: urls.count) : "\(title(fileCount: urls.count)) · \(first)"
    }

    public static func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    public static func displayPath(for url: URL) -> String {
        url.path
    }

    public static func byteCountLabel(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    public static func searchSegments(for urls: [URL]) -> [String] {
        var segments: [String] = []
        var seen = Set<String>()
        for url in urls {
            let name = displayName(for: url)
            if !name.isEmpty, seen.insert(name).inserted {
                segments.append(name)
            }
        }
        return segments
    }

    public static func footerLabel(fileCount: Int, totalByteCount: Int64?) -> String? {
        guard fileCount > 0 else { return nil }
        let heading = title(fileCount: fileCount)
        guard let totalByteCount, totalByteCount > 0 else { return heading }
        return "\(heading) · \(byteCountLabel(bytes: totalByteCount))"
    }

    public static func dedupKey(preview: String, fileURLs: [URL]) -> String {
        let paths = fileURLs.map(\.path).joined(separator: "\u{1e}")
        return "\(preview)\u{1f}\(paths)"
    }
}

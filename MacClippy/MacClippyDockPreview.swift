import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers

enum MacClippyDockPreviewContent {
    case loading
    case text(String)
    case image(Data)
    case video(URL)
    case files([URL])
    case error
}

// QuickLook-style preview metadata: the source app presentation, a relative
// timestamp, and an optional copy callback. Lets the preview header render
// the app icon + name + "• 2m ago" and wire a ⌘C Copy button without the
// controller having to reach into the view's internals.
struct MacClippyDockPreviewMetadata: Equatable {
    let sourceName: String
    let sourceIcon: NSImage?
    let sourceAccent: NSColor
    let relativeTime: String?
    let characterCount: Int

    static let unknown = MacClippyDockPreviewMetadata(
        sourceName: "Unknown",
        sourceIcon: nil,
        sourceAccent: NSColor.gray,
        relativeTime: nil,
        characterCount: 0
    )
}

// Preview is for fast inspection, while copy/paste always retains the full
// payload. Capping only the rendered text prevents TextKit from laying out
// very large clipboard documents during a Space transition.
enum MacClippyDockPreviewTextPolicy {
    static let maxRenderedCharacters = 120_000

    static func displayText(for text: String) -> String {
        guard text.count > maxRenderedCharacters else { return text }
        let remaining = text.count - maxRenderedCharacters
        return String(text.prefix(maxRenderedCharacters))
            + "\n\n— Preview shortened for performance · \(remaining) more characters —"
    }
}

// Maps a file-URL payload to the right preview content. A single pasted file
// URL whose extension conforms to UTType.movie is represented as a video
// preview; multiple files or non-video files keep the existing file list.
enum MacClippyDockPreviewContentPolicy {
    static func content(forFiles urls: [URL]) -> MacClippyDockPreviewContent {
        if urls.count == 1,
           let url = urls.first,
           let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .movie) {
            return .video(url)
        }
        return .files(urls)
    }
}

private enum MacClippyPreviewImageDownsampler {
    static func data(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

// Internal navigation direction for the preview header's prev/next chevrons.
// The controller wires this callback to the single helper that moves model
// focus and refreshes the preview, so the chevrons and the keyboard arrows
// share one path. Sendable so the closure can cross the SwiftUI boundary.
enum MacClippyPreviewNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

struct MacClippyDockPreviewView: View {
    let content: MacClippyDockPreviewContent
    let metadata: MacClippyDockPreviewMetadata
    let onNavigate: ((MacClippyPreviewNavigationDirection) -> Void)?
    let onCopy: (() -> Void)?
    let onDismiss: (() -> Void)?

    init(
        content: MacClippyDockPreviewContent,
        metadata: MacClippyDockPreviewMetadata = .unknown,
        onNavigate: ((MacClippyPreviewNavigationDirection) -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.content = content
        self.metadata = metadata
        self.onNavigate = onNavigate
        self.onCopy = onCopy
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider().opacity(0.5)

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider().opacity(0.5)

            previewFooter
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        // The AppKit preview panel supplies the size. Keeping the view flexible
        // lets the panel follow the available display area like Quick Look
        // instead of leaving a small fixed canvas inside a larger window.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }

    // QuickLook-style header: app icon + name + relative time on the left,
    // ⌘C Copy and Esc ✕ on the right, plus the prev/next chevrons.
    private var previewHeader: some View {
        HStack(spacing: 10) {
            if let icon = metadata.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(2)
                    .frame(width: 26, height: 26)
                    .background(Color(nsColor: metadata.sourceAccent).opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: metadata.sourceAccent).opacity(0.32), lineWidth: 1)
                    }
            } else {
                Image(systemName: "app.dashed")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: metadata.sourceAccent))
                    .frame(width: 26, height: 26)
                    .background(Color(nsColor: metadata.sourceAccent).opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color(nsColor: metadata.sourceAccent).opacity(0.32), lineWidth: 1)
                    }
            }
            Text(metadata.sourceName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let time = metadata.relativeTime {
                Text("• \(time) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            chevronButton(.previous)
            chevronButton(.next)
            if let onCopy {
                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("c", modifiers: .command)
            }
            Button {
                onDismiss?()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Esc to close")
        }
    }

    // Footer: character count + exit hint, QuickLook-style.
    private var previewFooter: some View {
        HStack(spacing: 8) {
            if metadata.characterCount > 0 {
                Text("\(metadata.characterCount) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text("Press Space or Esc to exit")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .text(value):
            // Use NSTextView for both modes. It keeps long clipboard payloads
            // in AppKit's native text layout path instead of asking SwiftUI to
            // repeatedly re-measure one very large Text during preview.
            let displayText = MacClippyDockPreviewTextPolicy.displayText(for: value.isEmpty ? "(empty)" : value)
            if MacClippyDockCodePolicy.isCode(value) {
                MacClippyDockPreviewTextView(
                    text: displayText,
                    monospaced: true,
                    foregroundColor: NSColor(calibratedRed: 0.85, green: 0.88, blue: 0.93, alpha: 1)
                )
                .background(Color(red: 0.10, green: 0.11, blue: 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                MacClippyDockPreviewTextView(
                    text: displayText,
                    monospaced: false,
                    foregroundColor: .labelColor
                )
            }
        case let .image(data):
            MacClippyDockPreviewImage(data: data)
        case let .video(url):
            MacClippyVideoPreview(url: url)
        case let .files(urls):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        HStack(spacing: 8) {
                            MacClippyDockPreviewFileIcon(url: url)
                            Text(url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        case .error:
            unavailableView
    }
}

private struct MacClippyDockPreviewImage: View {
    let data: Data

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: data) {
            image = nil
            failed = false
            let sourceData = data
            let renderedData = await Task.detached(priority: .userInitiated) {
                MacClippyPreviewImageDownsampler.data(sourceData, maxPixelSize: 1_600) ?? sourceData
            }.value
            guard !Task.isCancelled else { return }
            guard let decoded = NSImage(data: renderedData) else {
                failed = true
                return
            }
            image = decoded
        }
    }
}

private struct MacClippyDockPreviewFileIcon: View {
    let url: URL

    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .padding(3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .task(id: url) {
            let path = url.path
            let iconData = await Task.detached(priority: .utility) {
                NSWorkspace.shared.icon(forFile: path).tiffRepresentation
            }.value
            guard !Task.isCancelled else { return }
            icon = iconData.flatMap(NSImage.init(data:))
        }
    }
}

private struct MacClippyDockPreviewTextView: NSViewRepresentable {
    let text: String
    let monospaced: Bool
    let foregroundColor: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true

        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        update(textView, with: text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            update(textView, with: text)
        }
    }

    private func update(_ textView: NSTextView, with text: String) {
        let font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .foregroundColor: foregroundColor
                ]
            )
        )
    }
}

    private var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text("Preview unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Small native chevron button. The tap fires onNavigate; navigation itself
    // adds no spatial animation beyond the existing preview refresh, so it is
    // safe under Reduce Motion.
    private func chevronButton(_ direction: MacClippyPreviewNavigationDirection) -> some View {
        Button {
            onNavigate?(direction)
        } label: {
            Image(systemName: direction == .previous ? "chevron.left" : "chevron.right")
                .font(.headline)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(direction == .previous ? "Previous" : "Next")
    }
}

// Video preview for a single pasted movie URL. Uses AVKit.VideoPlayer with an
// AVPlayer bounded to the existing preview content area; native playback
// controls remain available. The player is created on appear and autoplays if
// practical, and is paused on disappear so leaving the preview never leaves a
// movie playing. Playback is preview-only: it does not touch the pasteboard or
// the store, so paste/storage behavior is unaffected.
private struct MacClippyVideoPreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            // Preview navigation can replace the URL while the view identity
            // remains stable. Replace the player on URL change so the previous
            // asset cannot keep decoding/playing in the background.
            player?.pause()
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

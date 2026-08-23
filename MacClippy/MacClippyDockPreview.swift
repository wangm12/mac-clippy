import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI

enum MacClippyDockPreviewContent {
    case loading
    case text(id: RecordID, value: String, kind: MacClippyClipboardPresentationKind)
    case richText(id: RecordID, attributed: NSAttributedString, plain: String)
    case color(id: RecordID, value: String, swatch: MacClippyColorSwatch)
    case image(id: RecordID, data: Data)
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
    let ocrText: String?

    static let unknown = MacClippyDockPreviewMetadata(
        sourceName: "Unknown",
        sourceIcon: nil,
        sourceAccent: NSColor.gray,
        relativeTime: nil,
        characterCount: 0,
        ocrText: nil
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
// File URLs stay on `.files`. The files surface embeds AppKit Quick Look
// for an existing path (image, movie, PDF) so Space matches Finder. Do not
// route movies into SwiftUI VideoPlayer — that AVKit representable aborts
// during NSHostingView.layout on current macOS.
enum MacClippyDockPreviewContentPolicy {
    static func content(forFiles urls: [URL]) -> MacClippyDockPreviewContent {
        .files(urls)
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
    let reduceMotion: Bool
    let onNavigate: ((MacClippyPreviewNavigationDirection) -> Void)?
    let onCopy: (() -> Void)?
    let recognizeOCRLayout: (@Sendable (CGImage) async throws -> MacClippyOCRResult)?
    let onCopyText: ((String) -> Void)?
    let onDismiss: (() -> Void)?

    @State private var imageOCRText: String?
    @State private var selectedImageText: String?

    private let contentIdentity: String

    init(
        content: MacClippyDockPreviewContent,
        metadata: MacClippyDockPreviewMetadata = .unknown,
        reduceMotion: Bool = false,
        onNavigate: ((MacClippyPreviewNavigationDirection) -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        recognizeOCRLayout: (@Sendable (CGImage) async throws -> MacClippyOCRResult)? = nil,
        onCopyText: ((String) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.content = content
        self.metadata = metadata
        self.reduceMotion = reduceMotion
        self.onNavigate = onNavigate
        self.onCopy = onCopy
        self.recognizeOCRLayout = recognizeOCRLayout
        self.onCopyText = onCopyText
        self.onDismiss = onDismiss
        contentIdentity = content.identity
        _imageOCRText = State(initialValue: nil)
        _selectedImageText = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewHeader
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 12)

            previewHairline

            contentView
                .id(contentIdentity)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(MacClippyDockTheme.previewSurfaceColor)

            previewHairline

            previewFooter
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
        }
        // The AppKit preview panel supplies the size. Keeping the view flexible
        // lets the panel follow the available display area like Quick Look
        // instead of leaving a small fixed canvas inside a larger window.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacClippyDockTheme.previewSurfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .inset(by: MacClippyDockTheme.cardBorderInset)
                .stroke(MacClippyDockTheme.interactiveRestBorder, lineWidth: MacClippyDockTheme.pillBorderWidth)
        }
        .onChange(of: contentIdentity) { _, _ in
            imageOCRText = nil
            selectedImageText = nil
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }

    // QuickLook-style header: app icon + name + relative time on the left,
    // ⌘C Copy and Esc ✕ on the right, plus the prev/next chevrons.
    private var previewHeader: some View {
        HStack(spacing: 10) {
            if let icon = metadata.sourceIcon {
                Image(nsImage: MacClippySourceAppIcon.prepared(icon, pointSize: 26))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(2)
                    .frame(width: 26, height: 26)
                    .background(Color(nsColor: metadata.sourceAccent).opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .inset(by: MacClippyDockTheme.cardBorderInset)
                            .stroke(Color(nsColor: metadata.sourceAccent).opacity(0.32), lineWidth: 1)
                    }
                    .environment(\.colorScheme, .light)
            } else {
                Image(systemName: "app.dashed")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(nsColor: metadata.sourceAccent))
                    .frame(width: 26, height: 26)
                    .background(Color(nsColor: metadata.sourceAccent).opacity(0.24), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .inset(by: MacClippyDockTheme.cardBorderInset)
                            .stroke(Color(nsColor: metadata.sourceAccent).opacity(0.32), lineWidth: 1)
                    }
            }
            Text(metadata.sourceName)
                .font(.body.weight(.semibold))
                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                .lineLimit(1)
            if let time = metadata.relativeTime {
                Text("• \(MacClippyDockTimestampPolicy.displayLabel(for: time))")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.contentMutedColor)
            }
            Spacer(minLength: 8)
            MacClippyPreviewChromeIconButton(
                systemImage: "chevron.left",
                accessibilityLabel: "Previous",
                action: { onNavigate?(.previous) }
            )
            MacClippyPreviewChromeIconButton(
                systemImage: "chevron.right",
                accessibilityLabel: "Next",
                action: { onNavigate?(.next) }
            )
            if let onCopy {
                MacClippyPreviewChromeLabelButton(
                    title: "Copy",
                    systemImage: "doc.on.doc",
                    accessibilityLabel: "Copy",
                    action: onCopy
                )
                .keyboardShortcut("c", modifiers: .command)
            }
            if let onCopyText,
               let imageText = MacClippyDockPreviewTextCopyPolicy.textToCopy(
                   selectedText: selectedImageText,
                   fullText: imageOCRText ?? metadata.ocrText
               ) {
                let copyingSelection = MacClippyDockPreviewTextCopyPolicy.isSelection(
                    selectedText: selectedImageText
                )
                MacClippyPreviewChromeLabelButton(
                    title: copyingSelection ? "Copy Selection" : "Copy Text",
                    systemImage: "text.cursor",
                    accessibilityLabel: copyingSelection ? "Copy selected text" : "Copy recognized text",
                    action: { onCopyText(imageText) }
                )
            }
            MacClippyPreviewChromeIconButton(
                systemImage: "xmark",
                accessibilityLabel: "Close preview",
                help: "Esc to close",
                action: { onDismiss?() }
            )
        }
    }

    // Footer: character count + exit hint, QuickLook-style.
    private var previewFooter: some View {
        HStack(spacing: 8) {
            if case .files = content {
                EmptyView()
            } else if let footerText = content.footerText(characterCount: metadata.characterCount) {
                Text(footerText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.contentMutedColor)
            }
            Spacer(minLength: 0)
            Text("Press Space or Esc to exit")
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacClippyDockTheme.contentMutedColor)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch content {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading preview")
        case let .text(_, value, kind):
            // Use NSTextView for both modes. It keeps long clipboard payloads
            // in AppKit's native text layout path instead of asking SwiftUI to
            // repeatedly re-measure one very large Text during preview.
            let displayText = MacClippyDockPreviewTextPolicy.displayText(for: value.isEmpty ? "(empty)" : value)
            switch kind {
            case .url:
                MacClippyDockPreviewURL(value: displayText)
            case .json, .code:
                MacClippyDockPreviewTextView(
                    text: displayText,
                    monospaced: true,
                    foregroundColor: MacClippyDockTheme.text,
                    backgroundColor: MacClippyDockTheme.previewWell
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .plain, .color:
                MacClippyDockPreviewTextView(
                    text: displayText,
                    monospaced: false,
                    foregroundColor: MacClippyDockTheme.text
                )
            }
        case let .richText(_, attributed, plain):
            let displayAttributed = plain.isEmpty
                ? NSAttributedString(string: "(empty)")
                : attributed
            MacClippyDockPreviewAttributedTextView(attributedText: displayAttributed)
        case let .color(_, value, swatch):
            MacClippyDockPreviewColor(value: value, swatch: swatch)
        case let .image(id, data):
            MacClippyDockPreviewImage(
                id: id,
                data: data,
                storedOCRText: metadata.ocrText,
                recognizeOCRLayout: recognizeOCRLayout,
                onOCRResult: { result in
                    imageOCRText = result?.fullText
                },
                onSelectionChanged: { selectedText in
                    selectedImageText = selectedText
                },
                onCopySelection: { selectedText in
                    onCopyText?(selectedText)
                }
            )
        case let .files(urls):
            filePreview(urls)
        case .error:
            unavailableView
        }
    }

    private var previewHairline: some View {
        Rectangle()
            .fill(MacClippyDockTheme.lineColor)
            .frame(height: 1)
            .allowsHitTesting(false)
    }
}

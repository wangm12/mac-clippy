import AppKit
import SwiftUI
import MacClippyCore
import MacClippyPlatform

extension MacClippyDockPreviewView {
    @ViewBuilder
    func filePreview(_ urls: [URL]) -> some View {
        if let url = MacClippyDockPreviewFileSurface.nativePreviewURL(in: urls) {
            switch MacClippyFilePresentation.mediaKind(for: url) {
            case .image:
                MacClippyFileImagePreview(url: url)
            case .movie:
                MacClippyVideoPreview(url: url, reduceMotion: reduceMotion)
            case .other:
                MacClippyQuickLookPreview(url: url, autostarts: !reduceMotion)
            }
        } else {
            unavailableView
        }
    }

    var unavailableView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(MacClippyDockTheme.contentMutedColor)
            Text("Preview unavailable")
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacClippyDockTheme.contentMutedColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview unavailable")
    }
}

struct MacClippyPreviewChromeIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var help: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isHovered ? MacClippyDockTheme.accentColor : MacClippyDockTheme.contentTextColor)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .macClippyChromeButtonStyle()
        .onContinuousHover { phase in
            isHovered = MacClippyDockHoverPolicy.isHovering(phase)
        }
        .accessibilityLabel(accessibilityLabel)
        .help(help ?? accessibilityLabel)
    }
}

struct MacClippyPreviewChromeLabelButton: View {
    let title: String
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(isHovered ? MacClippyDockTheme.accentColor : MacClippyDockTheme.contentTextColor)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 10)
                .frame(height: 28)
        }
        .macClippyChromeButtonStyle()
        .onContinuousHover { phase in
            isHovered = MacClippyDockHoverPolicy.isHovering(phase)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

struct MacClippyDockPreviewURL: View {
    let value: String

    private var url: URL? {
        MacClippyClipboardPresentation.url(fromPlainText: value)
    }

    private var pathAndQuery: String? {
        guard let url else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let suffix = url.query.map { "\(path)?\($0)" } ?? path
        return suffix == "/" ? nil : suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(url?.host(percentEncoded: false) ?? value)
                    .font(.headline)
                    .foregroundStyle(MacClippyDockTheme.contentTextColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let pathAndQuery {
                    Text(pathAndQuery)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            MacClippyDockPreviewTextView(
                text: value,
                monospaced: false,
                foregroundColor: MacClippyDockTheme.text
            )
        }
    }
}

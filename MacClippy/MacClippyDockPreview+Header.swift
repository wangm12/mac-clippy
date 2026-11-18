import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockPreviewView {
    @ViewBuilder
    private func previewSourceBadge(_ icon: NSImage) -> some View {
        let prepared = MacClippySourceAppIcon.prepared(icon, pointSize: 26)
        if let cgImage = MacClippySourceAppIcon.cgImage(prepared) {
            Image(decorative: cgImage, scale: MacClippySourceAppIcon.rasterScale, orientation: .up)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(nsImage: prepared)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    // QuickLook-style header: app icon + name + relative time on the left,
    // ⌘C Copy and Esc ✕ on the right, plus the prev/next chevrons.
    var previewHeader: some View {
        HStack(spacing: 10) {
            if let icon = metadata.sourceIcon {
                previewSourceBadge(icon)
                    .padding(2)
                    .frame(width: 26, height: 26)
                    .background(
                        Color(nsColor: metadata.sourceAccent).opacity(0.24),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
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
                    .background(
                        Color(nsColor: metadata.sourceAccent).opacity(0.24),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
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
            if let onPaste {
                MacClippyPreviewChromeLabelButton(
                    title: "Paste", systemImage: "arrow.down.doc",
                    accessibilityLabel: "Paste", action: onPaste)
            }
            if let onEdit {
                MacClippyPreviewChromeLabelButton(
                    title: "Edit", systemImage: "pencil",
                    accessibilityLabel: "Edit", action: onEdit)
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
    var previewFooter: some View {
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

}

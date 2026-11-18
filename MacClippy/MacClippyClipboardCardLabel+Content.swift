import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyClipboardCardLabel {
    @ViewBuilder
    var cardContent: some View {
        let item = context.item
        let classificationPreview = String(item.preview.prefix(2_000))
        let isText = item.contentKind == .text || item.contentKind == .html || item.contentKind == .rtf
        let presentationKind =
            isText
            ? MacClippyClipboardPresentation.kind(forPlainText: classificationPreview)
            : .plain

        Group {
            if item.contentKind == .files {
                cardFilesBody(item)
            } else if item.contentKind == .image {
                cardImageBody(item)
            } else if case .color(let swatch) = presentationKind {
                colorCardBody(swatch, item: item)
            } else if presentationKind == .url,
                let url = MacClippyClipboardPresentation.url(fromPlainText: classificationPreview) {
                urlCardBody(url, item: item)
            } else if presentationKind == .json {
                codeCardBody(item, lineLimit: 4)
            } else if presentationKind == .code {
                codeCardBody(item, lineLimit: nil)
            } else {
                plainTextCardBody(item)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: fillsCard ? .center : .topLeading
        )
    }

    @ViewBuilder
    func urlCardBody(_ url: URL, item: MacClippyHistoryEntry) -> some View {
        let originalURL = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        cardBodyWithNameTag(item: item) {
            VStack(alignment: .leading, spacing: 6) {
                highlighted(url.host(percentEncoded: false) ?? originalURL, font: .body.weight(.semibold))
                    .lineLimit(2)
                highlighted(
                    url.path + (url.query.map { "?\($0)" } ?? ""),
                    font: MacClippyDockCardMetrics.contentMonospacedFont
                )
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    func colorCardBody(_ swatch: MacClippyColorSwatch, item: MacClippyHistoryEntry) -> some View {
        cardBodyWithNameTag(item: item) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        Color(
                            red: Double(swatch.rgb.red) / 255,
                            green: Double(swatch.rgb.green) / 255,
                            blue: Double(swatch.rgb.blue) / 255
                        )
                    )
                    .frame(width: 28, height: 28)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
                    }
                highlighted(
                    swatch.hex,
                    font: MacClippyDockCardMetrics.contentMonospacedFont
                )
                .lineLimit(1)
                .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .accessibilityLabel("Color \(swatch.hex)")
        }
    }

    @ViewBuilder
    func cardFilesBody(_ item: MacClippyHistoryEntry) -> some View {
        let urls = item.fileURLs
        let pointSize = CGSize(
            width: MacClippyDockCardMetrics.width,
            height: MacClippyDockCardMetrics.height
        )
        if let url = urls.first, MacClippyFilePresentation.mediaKind(for: url) == .image {
            cardNamedPreview(
                MacClippyFileThumbnail(url: url, pointSize: pointSize)
                    .equatable()
                    .overlay(alignment: .bottom) {
                        ocrHitOverlay(for: item)
                    },
                name: MacClippyDockCardVisibleNamePolicy.text(for: item)
            )
        } else if let url = urls.first {
            VStack(spacing: 10) {
                MacClippyFileThumbnail(url: url, pointSize: CGSize(width: 96, height: 96))
                    .equatable()
                    .frame(width: 72, height: 72)
                cardVisibleName(MacClippyDockCardVisibleNamePolicy.text(for: item))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(MacClippyDockCardVisibleNamePolicy.text(for: item))
                .font(MacClippyDockCardMetrics.contentFont)
                .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func cardImageBody(_ item: MacClippyHistoryEntry) -> some View {
        cardNamedPreview(
            MacClippyCardImageThumbnail(
                itemID: item.id,
                load: loadThumbnail,
                cached: cachedThumbnail
            )
            .equatable()
            .overlay(alignment: .bottom) {
                ocrHitOverlay(for: item)
            },
            name: MacClippyDockCardVisibleNamePolicy.text(for: item)
        )
    }

    @ViewBuilder
    func ocrHitOverlay(for item: MacClippyHistoryEntry) -> some View {
        if let snippet = MacClippySearchFilterChipPolicy.ocrHitSnippet(
            ocrText: item.meta.ocrText,
            terms: context.highlightTerms
        ) {
            highlighted(
                snippet,
                font: .caption.weight(.semibold)
            )
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .padding(4)
            .accessibilityLabel("OCR match \(snippet)")
        }
    }

    @ViewBuilder
    func cardNamedPreview<Preview: View>(_ preview: Preview, name: String) -> some View {
        VStack(spacing: 8) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            cardVisibleName(name)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func cardVisibleName(_ name: String) -> some View {
        highlighted(
            name,
            font: .callout.weight(.semibold)
        )
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .truncationMode(.middle)
    }

    @ViewBuilder
    func cardBodyWithNameTag<Content: View>(
        item: MacClippyHistoryEntry,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = MacClippyDockCardNameTagPolicy.text(for: item) {
                cardNameTag(name)
            }
            content()
        }
    }

    func cardNameTag(_ name: String) -> some View {
        highlighted(
            name,
            font: MacClippyDockCardNameTagPolicy.font
        )
        .lineLimit(MacClippyDockCardNameTagPolicy.maximumLines)
        .multilineTextAlignment(.leading)
        .truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, MacClippyDockCardNameTagPolicy.horizontalPadding)
        .padding(.vertical, MacClippyDockCardNameTagPolicy.verticalPadding)
        .background(
            MacClippyDockTheme.accentSoftColor,
            in: RoundedRectangle(
                cornerRadius: MacClippyDockCardNameTagPolicy.cornerRadius,
                style: .continuous
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func plainTextCardBody(_ item: MacClippyHistoryEntry) -> some View {
        let text = item.preview.isEmpty ? "(empty)" : String(item.preview.prefix(2_000))
        cardBodyWithNameTag(item: item) {
            highlighted(
                text,
                font: MacClippyDockCardMetrics.contentFont
            )
            .lineSpacing(4)
            .lineLimit(9)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    func codeCardBody(_ item: MacClippyHistoryEntry, lineLimit: Int?) -> some View {
        cardBodyWithNameTag(item: item) {
            highlighted(
                String(item.preview.prefix(2_000)),
                font: MacClippyDockCardMetrics.contentMonospacedFont
            )
            .lineSpacing(3)
            .lineLimit(lineLimit ?? 11)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    func highlighted(
        _ text: String,
        font: Font,
        color: Color = MacClippyDockTheme.contentTextColor
    ) -> Text {
        MacClippyDockCardHighlight.text(
            text,
            font: font,
            color: color,
            terms: context.highlightTerms
        )
    }

    func label(for kind: ContentKind) -> String {
        switch kind {
        case .text: "Text"
        case .html: "HTML"
        case .rtf: "Rich text"
        case .image: "Image"
        case .files: "Files"
        }
    }
}

#if DEBUG
    enum MacClippyClipboardCardPreviewFactory {
        static let sampleText = "Remote clipboard test — copied from iPhone"

        @MainActor
        static func context(isRemoteClipboard: Bool) -> MacClippyClipboardCardContext {
            let now = Date()
            let item = MacClippyHistoryEntry(
                meta: ClipboardItemMeta(
                    id: .generate(),
                    created: now,
                    modified: now.addingTimeInterval(-90),
                    deviceID: .generate(),
                    lamport: 1,
                    preview: sampleText
                ),
                contentKind: .text,
                preview: sampleText,
                isRemoteClipboard: isRemoteClipboard
            )
            return MacClippyClipboardCardContext(
                item: item,
                index: 0,
                source: MacClippySourceAppPresentation(
                    displayName: "Safari",
                    icon: nil,
                    accent: NSColor.systemBlue
                ),
                dedupRun: 1,
                isSelected: false,
                activeBorder: false,
                isElevated: false,
                categories: [],
                highlightTerms: [],
                isPreviewVisible: false,
                sourcePresentationGeneration: 0
            )
        }

        @MainActor
        static func card(isRemoteClipboard: Bool) -> some View {
            MacClippyClipboardCardLabel(
                context: context(isRemoteClipboard: isRemoteClipboard),
                loadThumbnail: { _ in nil }
            )
            .padding(32)
            .background(MacClippyDockTheme.backdropColor)
        }
    }

    #Preview("Remote clipboard") {
        MacClippyClipboardCardPreviewFactory.card(isRemoteClipboard: true)
    }

    #Preview("Local clipboard") {
        MacClippyClipboardCardPreviewFactory.card(isRemoteClipboard: false)
    }
#endif
